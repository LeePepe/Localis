import Foundation
import LocalisModels

/// Translation between the persistent entities and the domain values.
///
/// Kept apart from the repository so the storage shape can change without the
/// query logic moving, and so this — the part that can silently corrupt a
/// transcript by mapping a field wrong — is readable on its own.
///
/// Unknown raw values decode to a safe default rather than throwing: a row
/// written by a newer build must never make an existing conversation
/// unreadable.
enum StoredMapping {
    // MARK: - Reading

    static func message(from stored: StoredMessage) -> Message {
        Message(
            id: stored.id,
            role: MessageRole(rawValue: stored.roleRaw) ?? .assistant,
            text: stored.text,
            createdAt: stored.createdAt,
            status: MessageStatus(rawValue: stored.statusRaw) ?? .complete,
            failure: failure(from: stored)
        )
    }

    static func session(from stored: StoredSession) -> Session {
        // Chronological order is a property of a transcript, not of the query
        // that fetched it — so it is imposed here, once.
        let ordered = (stored.messages ?? []).sorted { $0.createdAt < $1.createdAt }
        return Session(
            id: stored.id,
            hostID: hostID(from: stored),
            backendID: stored.backendID,
            title: stored.title,
            messages: ordered.map(message(from:)),
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            status: status(from: stored)
        )
    }

    /// The machine a stored row belongs to.
    ///
    /// A legacy row that migration has not attributed comes back as
    /// `.unattributed` rather than as a guess — see `UnattributedHost`.
    static func hostID(from stored: StoredSession) -> HostID {
        stored.hostID.map(HostID.init(rawValue:)) ?? .unattributed
    }

    /// The status a restored session comes back with.
    ///
    /// Two rules, and they answer different questions:
    ///
    /// **What survives.** `.error(_)` is a historical fact — the turn already
    /// failed, and nothing on next launch can re-derive it. Losing it means the
    /// user reopens the app to find yesterday's failed conversation sitting at
    /// `idle`, unable to tell whether their message was ever answered. So the
    /// whole enum is persisted, not a flag.
    ///
    /// **What is normalized away.** `idle` / `disconnected` / `connecting` /
    /// `streaming` all describe a live link, and a session read from disk has
    /// none — the process that owned it is gone. All four come back
    /// `.disconnected`.
    ///
    /// `idle` is included deliberately, and this is the one place it matters:
    /// `canSend` is true for `.idle` alone, so restoring it would let the
    /// composer offer to send over a connection that was never opened (FR-053).
    /// "Idle" means *connected and not busy* — after a relaunch the first half
    /// is false, so the state is not merely stale, it is wrong.
    ///
    /// Orphaning outranks any stored status: it is a fact about pairing rather
    /// than about a connection, and an unpaired host's session must not present
    /// as sendable however it was last stored.
    static func status(from stored: StoredSession) -> SessionStatus {
        guard !stored.isOrphaned, stored.hostID != nil else { return .orphaned }
        guard let decoded = decodeStatus(stored.statusJSON) else { return .disconnected }
        switch decoded {
        case .error, .orphaned:
            return decoded
        case .idle, .disconnected, .connecting, .streaming:
            return .disconnected
        }
    }

    /// Decodes a stored status, treating corruption as absence.
    ///
    /// A blob that fails to decode — a schema that moved, a truncated write —
    /// must not make the conversation unreadable. The caller falls back to
    /// `.disconnected`, which is the safe direction: it disables sending until a
    /// real connection exists rather than enabling it on a bad guess.
    private static func decodeStatus(_ json: String?) -> SessionStatus? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionStatus.self, from: data)
    }

    /// `availability` is deliberately not persisted, so a restored backend comes
    /// back `.available`.
    ///
    /// It answers "can the host route to this *right now*", which nothing on
    /// disk can know. Storing it would let a `not_logged_in` from last week grey
    /// out a backend the user has since signed into, and the row would stay
    /// greyed until the next `/v1/models` refresh. The live refresh is the only
    /// authority; the optimistic default merely avoids showing a stale negative.
    static func backend(from stored: StoredBackend) -> AgentBackend {
        AgentBackend(
            id: stored.backendID,
            displayName: stored.displayName,
            capabilities: Set(stored.capabilities.map(Capability.init(rawValue:)))
        )
    }

    /// The machine a stored row describes.
    ///
    /// **`pinnedSPKI` is always nil, and that is not a gap being papered over.**
    /// This layer does not hold the pin — `HostCredentialStore` does — so the
    /// only honest value here is "I do not know it". Reading a pin out of a
    /// column would mean the table had one, which is the second trust anchor
    /// `StoredHost` exists without. The host this returns therefore has
    /// `canConnect == false` even when `pairingState == .paired`; the app's
    /// composition point is what supplies the missing half.
    ///
    /// Unknown `pairingState` / `kind` raw values fall back rather than throw,
    /// for the usual reason — but the two fallbacks are chosen differently.
    ///
    /// `kind` is cosmetic, so an unrecognized one becomes `.other` and the row
    /// renders with a generic icon. `pairingState` decides whether a connection
    /// may open, so an unrecognized one becomes `.discovered`: not paired, not
    /// connectable, and visible in the list for the user to re-pair. Falling back
    /// to `.paired` would let a value this build cannot interpret authorise a
    /// connection.
    static func host(from stored: StoredHost) -> LocalisHost {
        LocalisHost(
            id: HostID(rawValue: stored.id),
            displayName: stored.displayName,
            endpoint: HostEndpoint(host: stored.endpointHost, port: stored.endpointPort),
            bridgeID: stored.bridgeID,
            pinnedSPKI: nil,
            pairingState: HostPairingState(rawValue: stored.pairingStateRaw) ?? .discovered,
            protocolVersion: stored.protocolVersion,
            kind: HostKind(rawValue: stored.kindRaw) ?? .other
        )
    }

    /// Capabilities as sorted wire strings, ready for the `capabilities` column.    ///
    /// Stored as raw strings, not as encoded `Capability` values: the column
    /// holds exactly what `/v1/models` sent, so a capability this build has no
    /// name for round-trips untouched (contract §2 — unknown values are ignored,
    /// never a reason to drop the backend). Sorted so a row rewritten with the
    /// same set compares equal instead of churning on `Set` ordering.
    static func capabilityStrings(_ capabilities: Set<Capability>) -> [String] {
        capabilities.map(\.rawValue).sorted()
    }

    /// The resume cursor for a message, if it has one.
    ///
    /// `lastSeq` may legitimately be `nil` — a turn can be opened before its
    /// first frame arrives — so only `turnID` is required. Without it there is
    /// no turn to address on the host, and a sequence number alone is not a
    /// resume point.
    static func cursor(from stored: StoredMessage) -> TurnCursor? {
        guard let turnID = stored.turnID else { return nil }
        return TurnCursor(turnID: turnID, lastSeq: stored.lastSeq)
    }

    /// Failure detail for a message, if the turn failed and the bridge sent it.
    ///
    /// Feeds both the restored `Message` and `reconcile(messageID:)`. The
    /// message matters most: the transcript is what the UI renders, so detail
    /// reachable only through reconciliation would still leave the message
    /// itself saying "Error".
    ///
    /// `Message.init` discards the detail unless the status is `.failed`, so a
    /// row whose status moved on cannot carry stale progress back into the
    /// domain — this function does not need to re-check that.
    ///
    /// Both halves are required: a `failed_at_ms` with no tool-call count is a
    /// partially-decoded frame, and rendering "failed 8 minutes in, after 0 tool
    /// calls" from it would state a number nobody reported.
    static func failure(from stored: StoredMessage) -> TurnFailure? {
        guard
            let failedAtMs = stored.failedAtMs,
            let toolCallsCompleted = stored.toolCallsCompleted
        else { return nil }
        return TurnFailure(failedAtMs: failedAtMs, toolCallsCompleted: toolCallsCompleted)
    }

    static func deliveryState(from stored: StoredMessage) -> StoredDeliveryState? {
        stored.deliveryStateRaw.flatMap(StoredDeliveryState.init(rawValue:))
    }

    // MARK: - Writing

    static func makeStored(_ message: Message) -> StoredMessage {
        let stored = StoredMessage(
            id: message.id,
            roleRaw: message.role.rawValue,
            text: message.text,
            createdAt: message.createdAt,
            statusRaw: message.status.rawValue
        )
        applyFailure(message.failure, to: stored)
        return stored
    }

    static func makeStored(_ session: Session, hostID: HostID?) -> StoredSession {
        let resolved = hostID ?? session.hostID
        return StoredSession(
            id: session.id,
            hostID: resolved.isUnattributed ? nil : resolved.rawValue,
            backendID: session.backendID,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            isOrphaned: session.status == .orphaned,
            statusJSON: encodeStatus(session.status)
        )
    }

    /// Encodes a status for storage, or `nil` if it cannot be encoded.
    ///
    /// A failure here loses the status but must never lose the session — the
    /// row still writes, and reads back `.disconnected`.
    static func encodeStatus(_ status: SessionStatus) -> String? {
        guard let data = try? JSONEncoder().encode(status) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Applies a domain message onto its stored row.
    ///
    /// `id` and `createdAt` are identity, not content, so they are not
    /// reassigned — a streaming chunk supersedes the text of a message, it does
    /// not make a different one.
    static func apply(_ message: Message, to stored: StoredMessage) {
        stored.text = message.text
        stored.statusRaw = message.status.rawValue
        stored.roleRaw = message.role.rawValue
        applyFailure(message.failure, to: stored)
    }

    /// Mirrors a message's failure detail onto its row, clearing it when absent.
    ///
    /// The clear is the load-bearing half. `Message` drops the detail the moment
    /// the status leaves `.failed`, so a retry that succeeds arrives here with
    /// `failure == nil`; leaving the old columns in place would resurrect
    /// "failed 8 minutes in" on a finished answer, where it reads as a fresh
    /// failure. Storage must not hold a fact the domain has already retracted.
    private static func applyFailure(_ failure: TurnFailure?, to stored: StoredMessage) {
        stored.failedAtMs = failure?.failedAtMs
        stored.toolCallsCompleted = failure?.toolCallsCompleted
    }

    /// Builds the row for a host, dropping the pin it may be carrying.
    ///
    /// A caller with a fully-composed host — pin included — can hand it straight
    /// to `save`, and the pin simply does not reach the table. That is
    /// deliberate: the alternative is refusing such a host, which would make
    /// "did this one come from the composition point?" something every call site
    /// has to know.
    static func makeStored(_ host: LocalisHost) -> StoredHost {
        StoredHost(
            id: host.id.rawValue,
            displayName: host.displayName,
            endpointHost: host.endpoint.host,
            endpointPort: host.endpoint.port,
            bridgeID: host.bridgeID,
            pairingStateRaw: host.pairingState.rawValue,
            protocolVersion: host.protocolVersion,
            kindRaw: host.kind.rawValue
        )
    }

    /// Applies a host onto its stored row.
    ///
    /// Every field except `id` is writable, and that asymmetry is the point: the
    /// id is fixed for life (FR-026) while the name, the address and the pairing
    /// state are exactly what changes during normal use. A machine that got a new
    /// DHCP lease is the same machine.
    ///
    /// The pin is not among them — it has no column. Revoking a host still
    /// removes its pin, just not here: `HostCredentialStore.removeCredentials(for:)`
    /// owns that, and `pairingState` is what this table records about it
    /// (FR-027).
    static func apply(_ host: LocalisHost, to stored: StoredHost) {
        stored.displayName = host.displayName
        stored.endpointHost = host.endpoint.host
        stored.endpointPort = host.endpoint.port
        stored.bridgeID = host.bridgeID
        stored.pairingStateRaw = host.pairingState.rawValue
        stored.protocolVersion = host.protocolVersion
        stored.kindRaw = host.kind.rawValue
    }

    /// Applies the mutable fields of a session onto its stored row.
    ///
    /// `hostID` is absent by design: a session's machine is fixed at creation
    /// and never moves (FR-030), so a save path that could change it would be a
    /// way to violate that invariant by accident.
    ///
    /// `isOrphaned` is likewise absent — orphaning is a pairing fact with its
    /// own path (`orphanSessions(ofHost:)`), so an ordinary save cannot
    /// un-orphan a session. `statusJSON` *is* written, because a turn ending in
    /// `.error` must survive a relaunch; on read, orphaning still wins over
    /// whatever status was stored.
    static func apply(_ session: Session, to stored: StoredSession) {
        stored.title = session.title
        stored.backendID = session.backendID
        stored.updatedAt = session.updatedAt
        stored.statusJSON = encodeStatus(session.status)
    }
}
