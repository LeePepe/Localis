import Foundation
import LocalisModels
import SwiftData

/// Result of attributing legacy sessions to a machine.
public struct MigrationReport: Hashable, Sendable {
    /// Sessions that gained a host.
    public let attributed: Int
    /// Sessions left read-only because attribution would have been a guess.
    public let orphaned: Int

    public init(attributed: Int, orphaned: Int) {
        self.attributed = attributed
        self.orphaned = orphaned
    }
}

/// SwiftData-backed persistence for sessions, messages, and backends.
///
/// A `ModelActor`, so every read and write runs on its own executor rather than
/// the main one — the store is written to on every streamed chunk, and doing
/// that on the main actor is what drops frames during a long answer.
///
/// **Queries are host-scoped by construction.** Callers pass a `SessionQuery`,
/// which cannot express "sessions using the backend named claude" without also
/// saying which machine — the cross-host bleed FR-029 calls a defect is not
/// reachable through this API.
///
/// Nothing here logs message text, titles, or paths. Constitution I applies to
/// the store as much as to the wire.
@ModelActor
public actor SwiftDataSessionRepository {
    /// Convenience initializer over a container.
    public init(container: ModelContainer) {
        self.init(modelContainer: container)
    }

    // MARK: - Reading

    /// Every session, newest activity first, orphans included.
    ///
    /// The session list shows unpaired machines' history too — it is readable,
    /// just not sendable (FR-036).
    public func allSessions() throws -> [Session] {
        let descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(StoredMapping.session(from:))
    }

    /// Sessions matching a host-scoped query, newest activity first.
    public func sessions(matching query: SessionQuery) throws -> [Session] {
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: Self.predicate(for: query),
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(StoredMapping.session(from:))
    }

    public func session(id: UUID) throws -> Session? {
        try stored(id: id).map(StoredMapping.session(from:))
    }

    /// Every known machine, alphabetical so the host picker is stable.
    ///
    /// Sorted here rather than by the caller, same as `backends(ofHost:)`: this
    /// is a list the user taps, and rows that reorder between launches are rows
    /// they mis-tap.
    public func hosts() throws -> [LocalisHost] {
        try modelContext.fetch(FetchDescriptor<StoredHost>())
            .map(StoredMapping.host(from:))
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    public func host(id: HostID) throws -> LocalisHost? {
        try storedHost(id: id).map(StoredMapping.host(from:))
    }

    /// Backends advertised by one machine, alphabetical so the picker is stable.
    public func backends(ofHost hostID: HostID) throws -> [AgentBackend] {
        let raw = hostID.rawValue
        let descriptor = FetchDescriptor<StoredBackend>(
            predicate: #Predicate { $0.hostID == raw }
        )
        return try modelContext.fetch(descriptor)
            .map(StoredMapping.backend(from:))
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// Total stored messages. Diagnostics and migration assertions only.
    public func storedMessageCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<StoredMessage>())
    }

    // MARK: - Writing

    /// Creates a session on the machine it already names.
    ///
    /// A no-op if the id already exists: the binding is fixed for life
    /// (FR-030), so re-creating an existing session must not move it.
    public func create(_ session: Session) throws {
        guard try stored(id: session.id) == nil else { return }
        try insert(session, hostID: session.hostID)
    }

    /// Creates a session with no machine — legacy rows and test fixtures.
    ///
    /// The row is written with a null host, which is the on-disk shape of data
    /// predating Amendment A. It is what `migrateHostAttribution` looks for.
    public func createUnattributed(_ session: Session) throws {
        guard try stored(id: session.id) == nil else { return }
        try insert(session, hostID: .unattributed)
    }

    /// Saves a session's mutable fields and reconciles its transcript.
    ///
    /// Messages are matched by id: existing ones are updated in place and new
    /// ones inserted, so a streamed chunk rewrites one row rather than the
    /// whole conversation.
    public func save(_ session: Session) throws {
        guard let row = try stored(id: session.id) else { return }
        StoredMapping.apply(session, to: row)

        var existing = Dictionary(
            (row.messages ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for message in session.messages {
            if let found = existing.removeValue(forKey: message.id) {
                StoredMapping.apply(message, to: found)
            } else {
                let inserted = StoredMapping.makeStored(message)
                inserted.session = row
                modelContext.insert(inserted)
            }
        }
        // Anything left was removed from the transcript upstream.
        for orphan in existing.values {
            modelContext.delete(orphan)
        }
        try modelContext.save()
    }

    /// Appends one message.
    ///
    /// The streaming write path: it touches a single row, so it stays cheap
    /// however long the conversation gets.
    public func append(_ message: Message, toSession sessionID: UUID, at timestamp: Date) throws {
        guard let row = try stored(id: sessionID) else { return }
        let inserted = StoredMapping.makeStored(message)
        inserted.session = row
        modelContext.insert(inserted)
        row.updatedAt = timestamp
        try modelContext.save()
    }

    public func save(_ backend: AgentBackend, on hostID: HostID) throws {
        let raw = hostID.rawValue
        let backendID = backend.id
        let descriptor = FetchDescriptor<StoredBackend>(
            predicate: #Predicate { $0.hostID == raw && $0.backendID == backendID }
        )
        let capabilities = StoredMapping.capabilityStrings(backend.capabilities)
        if let existing = try modelContext.fetch(descriptor).first {
            existing.displayName = backend.displayName
            existing.capabilities = capabilities
        } else {
            modelContext.insert(
                StoredBackend(
                    hostID: raw,
                    backendID: backend.id,
                    displayName: backend.displayName,
                    capabilities: capabilities
                )
            )
        }
        try modelContext.save()
    }

    /// Inserts a machine, or updates the one that already has this id.
    ///
    /// Upsert rather than insert because the id is fixed for life (FR-026):
    /// a rename, a DHCP move and a completed pairing all arrive here as a save
    /// on an id that already exists. Inserting would put the same Mac in the
    /// list twice, and half its sessions would point at the copy the user
    /// didn't pick.
    ///
    /// Refuses `HostID.unattributed`. That value is a marker meaning "no
    /// machine", and a row for it would appear in `hosts()` as a pairable Mac
    /// the user could tap. It is rejected here rather than filtered on read so
    /// the store never holds one at all — see `UnattributedHost`.
    public func save(_ host: LocalisHost) throws {
        guard !host.id.isUnattributed else {
            throw LocalisError.invalidInput(field: "hostID")
        }
        if let existing = try storedHost(id: host.id) {
            StoredMapping.apply(host, to: existing)
        } else {
            modelContext.insert(StoredMapping.makeStored(host))
        }
        try modelContext.save()
    }

    // MARK: - Deleting

    /// Deletes a session and its transcript. Idempotent.
    public func delete(id: UUID) throws {
        guard let row = try stored(id: id) else { return }
        modelContext.delete(row)
        try modelContext.save()
    }

    /// Forgets a machine. Idempotent.
    ///
    /// **Its conversations are deliberately left behind.** Removing a machine
    /// from the list is the same promise unpairing makes: credentials go,
    /// history stays readable (FR-027, FR-036). This is also why the schema has
    /// no cascade from host to session — a relationship with `.cascade` would
    /// make this method quietly destroy transcripts, and it would look like the
    /// tidier design right up until a user lost a year of work.
    public func deleteHost(id hostID: HostID) throws {
        guard let row = try storedHost(id: hostID) else { return }
        modelContext.delete(row)
        try modelContext.save()
    }

    /// Deletes one machine's backend. Same-named backends elsewhere are
    /// untouched.
    public func deleteBackend(id backendID: String, on hostID: HostID) throws {
        let raw = hostID.rawValue
        let descriptor = FetchDescriptor<StoredBackend>(
            predicate: #Predicate { $0.hostID == raw && $0.backendID == backendID }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    // MARK: - Unpairing

    /// Marks a machine's sessions read-only without deleting them (FR-027).
    ///
    /// Unpairing removes credentials, not history. The host binding survives —
    /// it is immutable for life (FR-030) and is what lets a later re-pair find
    /// these conversations again — and only sending is disabled.
    public func orphanSessions(ofHost hostID: HostID) throws {
        let raw = hostID.rawValue
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.hostID == raw }
        )
        for row in try modelContext.fetch(descriptor) {
            row.isOrphaned = true
        }
        try modelContext.save()
    }

    /// Reactivates a machine's sessions when it is paired again.
    ///
    /// Only rows already bound to this machine are touched, so reactivation can
    /// never claim another machine's conversations.
    public func reactivateSessions(ofHost hostID: HostID) throws {
        let raw = hostID.rawValue
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.hostID == raw }
        )
        for row in try modelContext.fetch(descriptor) {
            row.isOrphaned = false
        }
        try modelContext.save()
    }

    /// Attributes never-migrated sessions to a machine, by explicit user choice.
    ///
    /// Only rows with no host at all are adopted — a session already on a
    /// machine is left alone, so adoption can never move a live conversation.
    public func adopt(sessionIDs: [UUID], on hostID: HostID) throws {
        for id in sessionIDs {
            guard let row = try stored(id: id), row.hostID == nil else { continue }
            row.hostID = hostID.rawValue
            row.isOrphaned = false
        }
        try modelContext.save()
    }

    // MARK: - Background resume

    /// Records where a streamed turn got to, so it can be picked up later.
    ///
    /// Persisted rather than held in memory because "backgrounded" and "killed"
    /// are the same case on the wire (Amendment C §1.2) — a cursor that only
    /// lived in a running process would cover just one of them.
    ///
    /// `failure` carries the `x-localis-turn-end` detail so the app can say
    /// "failed 8 minutes in, after 3 tool calls" even if the user force-quit
    /// before the message was ever shown.
    public func recordTurn(
        messageID: UUID,
        state: StoredDeliveryState,
        cursor: TurnCursor?,
        failure: TurnFailure? = nil
    ) throws {
        guard let row = try storedMessage(id: messageID) else { return }
        row.deliveryStateRaw = state.rawValue
        row.turnID = cursor?.turnID
        row.lastSeq = cursor?.lastSeq
        row.failedAtMs = failure?.failedAtMs
        row.toolCallsCompleted = failure?.toolCallsCompleted
        try modelContext.save()
    }

    /// Marks a turn's output as cut off — recorded as `interrupted`, never
    /// `complete` (contract §3.3).
    ///
    /// Truncation is the one case where the honest answer is worse-looking than
    /// the dishonest one. Storing a cut-off answer as `complete` presents a
    /// partial reply as the whole thing, and the user has no way to know the
    /// rest existed. `interrupted` says we lost it, and is retryable — there is
    /// nothing left on the host to resume, so the cursor is cleared with it.
    public func recordTruncation(messageID: UUID) throws {
        guard let row = try storedMessage(id: messageID) else { return }
        row.deliveryStateRaw = StoredDeliveryState.interrupted.rawValue
        row.statusRaw = MessageStatus.interrupted.rawValue
        row.turnID = nil
        row.lastSeq = nil
        try modelContext.save()
    }

    /// Advances a turn's cursor, dropping replayed frames.
    ///
    /// Returns whether the frame was new. `accepts(turnID:seq:)` decides — dedup
    /// and the turn check live on the cursor, in one place, so a resume boundary
    /// cannot double-write text and one turn's frame cannot mark another's
    /// progress.
    @discardableResult
    public func advanceTurn(messageID: UUID, turnID: String, seq: Int) throws -> Bool {
        guard let row = try storedMessage(id: messageID) else { return false }
        let current = StoredMapping.cursor(from: row) ?? TurnCursor(turnID: turnID)
        guard current.accepts(turnID: turnID, seq: seq) else { return false }
        let advanced = current.advanced(to: seq)
        row.turnID = advanced.turnID
        row.lastSeq = advanced.lastSeq
        try modelContext.save()
        return true
    }

    /// What to do about a turn on return: it finished, it's still running on the
    /// host, it failed, or it's gone.
    ///
    /// A message with no recorded delivery state never streamed, so there is
    /// nothing to reconcile — `.settled`.
    public func reconcile(messageID: UUID) throws -> TurnReconciliation {
        guard
            let row = try storedMessage(id: messageID),
            let state = StoredMapping.deliveryState(from: row)
        else { return .settled }
        return TurnReconciliation.resolve(
            state: state,
            cursor: StoredMapping.cursor(from: row),
            failure: StoredMapping.failure(from: row)
        )
    }

    /// Every turn that needs attention after a relaunch, with its outcome.
    ///
    /// The reconnect path reads this to tell "resume this" from "offer a retry"
    /// — the distinction that stops a retry button from starting a second job on
    /// the user's machine (Amendment C §1.5).
    public func pendingTurns() throws -> [(messageID: UUID, outcome: TurnReconciliation)] {
        let live = [StoredDeliveryState.streaming.rawValue, StoredDeliveryState.detached.rawValue]
        let descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate { message in
                message.deliveryStateRaw.flatMap { live.contains($0) } ?? false
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).compactMap { row in
            guard let state = StoredMapping.deliveryState(from: row) else { return nil }
            return (
                row.id,
                TurnReconciliation.resolve(
                    state: state,
                    cursor: StoredMapping.cursor(from: row),
                    failure: StoredMapping.failure(from: row)
                )
            )
        }
    }

    // MARK: - Migration

    /// Attributes legacy sessions to a machine (FR-038).
    ///
    /// Never deletes and never guesses: one paired host means certainty, and
    /// anything else leaves the sessions readable and orphaned for the user to
    /// resolve. Idempotent — sessions that already have a host are skipped, so
    /// a re-run is a no-op rather than a reshuffle.
    @discardableResult
    public func migrateHostAttribution(pairedHosts: [HostID]) throws -> MigrationReport {
        let plan = HostAttributionPlan.resolve(pairedHosts: pairedHosts)
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.hostID == nil }
        )
        var attributed = 0
        var orphaned = 0
        for row in try modelContext.fetch(descriptor) {
            switch plan.attribution(forLegacySessionWith: nil) {
            case .attributed(let hostID):
                row.hostID = hostID.rawValue
                row.isOrphaned = false
                attributed += 1
            case .orphaned:
                row.isOrphaned = true
                orphaned += 1
            }
        }
        try modelContext.save()
        return MigrationReport(attributed: attributed, orphaned: orphaned)
    }

    // MARK: - Internals

    private func insert(_ session: Session, hostID: HostID) throws {
        let row = StoredMapping.makeStored(session, hostID: hostID)
        modelContext.insert(row)
        for message in session.messages {
            let stored = StoredMapping.makeStored(message)
            stored.session = row
            modelContext.insert(stored)
        }
        try modelContext.save()
    }

    private func stored(id: UUID) throws -> StoredSession? {
        var descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedMessage(id: UUID) throws -> StoredMessage? {
        var descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedHost(id hostID: HostID) throws -> StoredHost? {
        let raw = hostID.rawValue
        var descriptor = FetchDescriptor<StoredHost>(predicate: #Predicate { $0.id == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Compiles a `SessionQuery` into a predicate.
    ///
    /// Every branch pins the host first. There is deliberately no branch that
    /// filters on `backendID` alone — that is the shape FR-029 calls a defect.
    private static func predicate(for query: SessionQuery) -> Predicate<StoredSession> {
        guard !query.isUnattributedQuery else {
            return #Predicate { $0.hostID == nil }
        }
        let raw = query.hostID.rawValue
        guard let backendID = query.backendID else {
            return #Predicate { $0.hostID == raw }
        }
        return #Predicate { $0.hostID == raw && $0.backendID == backendID }
    }
}
