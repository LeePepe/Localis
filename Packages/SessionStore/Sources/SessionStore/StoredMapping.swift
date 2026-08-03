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
            status: MessageStatus(rawValue: stored.statusRaw) ?? .complete
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
    /// Only two outcomes are reachable from disk. `orphaned` is a durable fact
    /// about pairing and survives a relaunch; everything else in `SessionStatus`
    /// describes a live link, and a session restored from disk has none yet —
    /// claiming `idle` here would let the composer offer to send over a
    /// connection that was never opened (FR-053).
    static func status(from stored: StoredSession) -> SessionStatus {
        (stored.isOrphaned || stored.hostID == nil) ? .orphaned : .disconnected
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
            capabilities: Set(stored.capabilities)
        )
    }

    /// The resume cursor for a message, if it has one.
    ///
    /// Both halves must be present — a `turnID` with no sequence, or the
    /// reverse, is not a resume point and is treated as absent rather than
    /// patched up with a default.
    static func cursor(from stored: StoredMessage) -> ResumeCursor? {
        guard let turnID = stored.turnID, let lastSeq = stored.lastSeq else { return nil }
        return ResumeCursor(turnID: turnID, lastSeq: lastSeq)
    }

    static func deliveryState(from stored: StoredMessage) -> StoredDeliveryState? {
        stored.deliveryStateRaw.flatMap(StoredDeliveryState.init(rawValue:))
    }

    // MARK: - Writing

    static func makeStored(_ message: Message) -> StoredMessage {
        StoredMessage(
            id: message.id,
            roleRaw: message.role.rawValue,
            text: message.text,
            createdAt: message.createdAt,
            statusRaw: message.status.rawValue
        )
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
            isOrphaned: session.status == .orphaned
        )
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
    }

    /// Applies the mutable fields of a session onto its stored row.
    ///
    /// `hostID` is absent by design: a session's machine is fixed at creation
    /// and never moves (FR-030), so a save path that could change it would be a
    /// way to violate that invariant by accident. Orphaning is a pairing fact
    /// and has its own path (`orphanSessions(ofHost:)`), so an ordinary save
    /// cannot un-orphan a session either.
    static func apply(_ session: Session, to stored: StoredSession) {
        stored.title = session.title
        stored.backendID = session.backendID
        stored.updatedAt = session.updatedAt
    }
}
