import Foundation
import LocalisModels

/// Persistence boundary for sessions and backends.
///
/// Repository pattern: business logic depends on this protocol, not on the
/// storage mechanism, so the on-disk format can change (and tests can run
/// in-memory) without touching callers.
///
/// **Every backend-facing operation takes a host.** A backend id is a wire
/// string that is unique only *within* one machine (FR-029), so `deleteBackend(
/// id: "claude")` with no host names two different backends when two machines
/// are paired. The host parameter is not a convenience — it is what makes these
/// signatures denote one thing each.
public protocol SessionRepository: Sendable {
    /// Every session, newest activity first, orphaned history included (FR-036).
    func allSessions() async throws -> [Session]
    /// Sessions narrowed by a host-scoped query.
    func sessions(matching query: SessionQuery) async throws -> [Session]
    func session(id: UUID) async throws -> Session?
    /// Inserts a session on the machine it names. No-op if the id exists —
    /// the host binding is fixed for life (FR-030).
    func create(_ session: Session) async throws
    /// Updates a stored session's mutable fields and transcript.
    func save(_ session: Session) async throws
    func delete(id: UUID) async throws

    /// Backends advertised by one machine, alphabetical.
    func backends(ofHost hostID: HostID) async throws -> [AgentBackend]
    func save(_ backend: AgentBackend, on hostID: HostID) async throws
    func deleteBackend(id: String, on hostID: HostID) async throws
}

extension SwiftDataSessionRepository: SessionRepository {}

/// In-memory `SessionRepository`.
///
/// An actor so concurrent readers/writers are serialized without locks. Used by
/// tests and previews; `SwiftDataSessionRepository` is the disk-backed
/// implementation behind the same protocol.
public actor InMemorySessionRepository: SessionRepository {
    private var sessions: [UUID: Session]
    /// Keyed by `BackendRef`, never by backend id: the same name on two
    /// machines must be two entries, not one that overwrites the other.
    private var backends: [BackendRef: AgentBackend]

    public init(sessions: [Session] = [], backends: [BackendRef: AgentBackend] = [:]) {
        self.sessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.backends = backends
    }

    // MARK: - Sessions

    /// Newest-updated first — the order the session list renders in.
    public func allSessions() async throws -> [Session] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func sessions(matching query: SessionQuery) async throws -> [Session] {
        try await allSessions().filter {
            query.matches(hostID: $0.hostID, backendID: $0.backendID)
        }
    }

    public func session(id: UUID) async throws -> Session? {
        sessions[id]
    }

    public func create(_ session: Session) async throws {
        guard sessions[session.id] == nil else { return }
        sessions[session.id] = session
    }

    /// Updates an existing session, preserving its host binding (FR-030).
    ///
    /// A save carrying a different `hostID` keeps the stored one rather than
    /// moving the conversation — the same rule the SwiftData implementation
    /// enforces by not mapping `hostID` on the save path.
    public func save(_ session: Session) async throws {
        guard let existing = sessions[session.id] else { return }
        sessions[session.id] = Session(
            id: existing.id,
            hostID: existing.hostID,
            backendID: session.backendID,
            title: session.title,
            messages: session.messages,
            createdAt: existing.createdAt,
            updatedAt: session.updatedAt,
            status: session.status
        )
    }

    public func delete(id: UUID) async throws {
        sessions[id] = nil
    }

    // MARK: - Backends

    /// Stable alphabetical order so the backend picker doesn't jump around.
    public func backends(ofHost hostID: HostID) async throws -> [AgentBackend] {
        backends
            .filter { $0.key.hostID == hostID }
            .values
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    public func save(_ backend: AgentBackend, on hostID: HostID) async throws {
        backends[backend.ref(on: hostID)] = backend
    }

    public func deleteBackend(id: String, on hostID: HostID) async throws {
        backends[BackendRef(hostID: hostID, backendID: id)] = nil
    }
}
