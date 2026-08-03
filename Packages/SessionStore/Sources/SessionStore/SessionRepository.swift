import Foundation
import LocalisModels

/// Persistence boundary for sessions and backends.
///
/// Repository pattern: business logic depends on this protocol, not on the
/// storage mechanism, so the on-disk format can change (and tests can run
/// in-memory) without touching callers.
public protocol SessionRepository: Sendable {
    func allSessions() async throws -> [Session]
    func session(id: UUID) async throws -> Session?
    func save(_ session: Session) async throws
    func delete(id: UUID) async throws

    func allBackends() async throws -> [AgentBackend]
    func save(_ backend: AgentBackend) async throws
    func deleteBackend(id: UUID) async throws
}

/// In-memory `SessionRepository`.
///
/// An actor so concurrent readers/writers are serialized without locks. Used by
/// tests and previews today; the disk-backed implementation will conform to the
/// same protocol and swap in behind it.
public actor InMemorySessionRepository: SessionRepository {
    private var sessions: [UUID: Session]
    private var backends: [UUID: AgentBackend]

    public init(sessions: [Session] = [], backends: [AgentBackend] = []) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
    }

    // MARK: - Sessions

    /// Newest-updated first — the order the session list renders in.
    public func allSessions() async throws -> [Session] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func session(id: UUID) async throws -> Session? {
        sessions[id]
    }

    public func save(_ session: Session) async throws {
        sessions[session.id] = session
    }

    public func delete(id: UUID) async throws {
        sessions[id] = nil
    }

    // MARK: - Backends

    /// Stable alphabetical order so the backend picker doesn't jump around.
    public func allBackends() async throws -> [AgentBackend] {
        backends.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    public func save(_ backend: AgentBackend) async throws {
        backends[backend.id] = backend
    }

    public func deleteBackend(id: UUID) async throws {
        backends[id] = nil
    }
}
