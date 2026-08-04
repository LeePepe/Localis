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

    /// Every paired or discovered machine, alphabetical.
    func hosts() async throws -> [LocalisHost]
    func host(id: HostID) async throws -> LocalisHost?
    /// Inserts a machine or updates the one with this id — the id is fixed for
    /// life (FR-026), so a rename or a new address is an update, not a new Mac.
    ///
    /// Throws for `HostID.unattributed`: that value means "no machine", and a
    /// row for it would show up in `hosts()` as one the user could tap.
    func save(_ host: LocalisHost) async throws
    /// Forgets a machine. Its conversations stay readable (FR-027, FR-036).
    func deleteHost(id: HostID) async throws
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
    private var hosts: [HostID: LocalisHost]

    public init(
        sessions: [Session] = [],
        backends: [BackendRef: AgentBackend] = [:],
        hosts: [LocalisHost] = []
    ) {
        self.sessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.backends = backends
        // Seeded hosts go through the same pin-stripping as saved ones. A seed
        // that kept its pin would be a host this repository can return but the
        // disk-backed one never can, and the preview or test built on it would
        // be demonstrating connectivity the shipping app cannot reach.
        self.hosts = Dictionary(
            hosts.map { ($0.id, Self.withoutPin($0)) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// A copy with no pinned certificate.
    ///
    /// One helper for both the seed path and `save`, so the two cannot drift
    /// into disagreeing about what this store holds.
    private static func withoutPin(_ host: LocalisHost) -> LocalisHost {
        LocalisHost(
            id: host.id,
            displayName: host.displayName,
            endpoint: host.endpoint,
            bridgeID: host.bridgeID,
            pinnedSPKI: nil,
            pairingState: host.pairingState,
            protocolVersion: host.protocolVersion,
            kind: host.kind
        )
    }

    /// A session as it comes back out of storage.
    ///
    /// Applies `StoredMapping.restoredStatus(of:isAttributed:)` — the same rule
    /// the SwiftData store applies on read, called rather than reimplemented.
    ///
    /// Doing this on the way *out* rather than on the way in is deliberate: a
    /// caller that saves and immediately re-reads must see what a relaunch would
    /// show, and normalising at write time would additionally destroy the
    /// distinction between a status that was never stored and one that was
    /// stored as `.disconnected`.
    private static func restored(_ session: Session) -> Session {
        let status = StoredMapping.restoredStatus(
            of: session.status,
            isAttributed: !session.hostID.isUnattributed
        )
        guard status != session.status else { return session }
        return Session(
            id: session.id,
            hostID: session.hostID,
            backendID: session.backendID,
            title: session.title,
            messages: session.messages,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            status: status
        )
    }

    /// A backend as it comes back out of storage, with availability dropped.
    ///
    /// `availability` answers "can the host route to this *right now*", which no
    /// store can know. The SwiftData one drops it by not having a column; this
    /// one has to drop it explicitly, and must, or a preview would show a
    /// backend greyed out by a week-old `not_logged_in`.
    ///
    /// **The live refresh this defers to does not exist yet (#29).** Dropping a
    /// stale negative is only safe if something later supplies a fresh one, and
    /// measured 2026-08-04 over `Packages/*/Sources` and `Localis/Sources`,
    /// nothing does: `withAvailability` has exactly one production caller — this
    /// line, setting `.available`. `BackendCatalog` does decode
    /// `.unavailable(reason:)` off the wire correctly, but the only consumer of
    /// that catalog is `BridgeClient.probe`, which reads `isAvailable` into a
    /// `Bool` and discards the backend itself; nothing stores it or hands it to
    /// a view. So every `AgentBackend` a screen can reach came through here and
    /// says `.available`, and `SessionDetailView`'s "isn't signed in" branch is
    /// unreachable. (Positive control for the search: `availability` matches 18
    /// lines over those paths, so the one-caller result is not a narrow path.)
    ///
    /// Note this is **not** waiting on task #40. That one gives `probe` a return
    /// type that can carry a reason; it does not give the decoded `availability`
    /// a route to the UI, and this line would still overwrite it if it had one.
    /// Delete this note when a production caller passes something other than
    /// `.available` to `withAvailability`.
    private static func restored(_ backend: AgentBackend) -> AgentBackend {
        backend.withAvailability(.available)
    }

    // MARK: - Sessions

    /// Newest-updated first — the order the session list renders in.
    public func allSessions() async throws -> [Session] {
        sessions.values.map(Self.restored).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func sessions(matching query: SessionQuery) async throws -> [Session] {
        try await allSessions().filter {
            query.matches(hostID: $0.hostID, backendID: $0.backendID)
        }
    }

    public func session(id: UUID) async throws -> Session? {
        sessions[id].map(Self.restored)
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
            .map(Self.restored)
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    public func save(_ backend: AgentBackend, on hostID: HostID) async throws {
        backends[backend.ref(on: hostID)] = backend
    }

    public func deleteBackend(id: String, on hostID: HostID) async throws {
        backends[BackendRef(hostID: hostID, backendID: id)] = nil
    }

    // MARK: - Hosts

    /// Same alphabetical order the SwiftData implementation returns.
    ///
    /// The two implementations sit behind one protocol, so a difference here is
    /// a difference the tests cannot see: a UI test passing on this one would
    /// say nothing about the store the app actually ships with.
    public func hosts() async throws -> [LocalisHost] {
        hosts.values.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    public func host(id: HostID) async throws -> LocalisHost? {
        hosts[id]
    }

    /// Upsert, and the same refusal to store the "no machine" marker.
    ///
    /// The pin is dropped here exactly as the disk-backed store drops it, and
    /// that parity is the reason this implementation exists. An in-memory store
    /// that remembered pins would let a UI test prove `canConnect` after a
    /// reload — a fact that is false in the shipping app, where the pin lives in
    /// the Keychain and only the composition point can put the halves together.
    public func save(_ host: LocalisHost) async throws {
        guard !host.id.isUnattributed else {
            throw LocalisError.invalidInput(field: "hostID")
        }
        hosts[host.id] = Self.withoutPin(host)
    }

    /// Forgets the machine and leaves its sessions alone (FR-027, FR-036).
    public func deleteHost(id: HostID) async throws {
        hosts[id] = nil
    }
}
