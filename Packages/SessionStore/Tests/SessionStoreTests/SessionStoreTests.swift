import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// The in-memory repository, held to the same host-scoping contract as the
/// SwiftData one — it is what previews and other packages' tests run against,
/// so a laxer implementation here would let a cross-host bug pass CI.
@Suite("InMemorySessionRepository")
struct InMemorySessionRepositoryTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private static let hostB = HostID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    private static func makeSession(
        title: String,
        updatedAt: Date,
        hostID: HostID = hostA,
        backendID: String = "test-backend"
    ) -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: backendID,
            title: title,
            createdAt: t0,
            updatedAt: updatedAt
        )
    }

    private static func makeBackend(name: String) -> AgentBackend {
        AgentBackend(
            id: name.lowercased(),
            displayName: name,
            capabilities: ["streaming"]
        )
    }

    @Test("creating then reading returns the session")
    func createAndRead() async throws {
        let repository = InMemorySessionRepository()
        let session = Self.makeSession(title: "First", updatedAt: Self.t0)

        try await repository.create(session)

        #expect(try await repository.session(id: session.id)?.title == "First")
    }

    @Test("sessions are returned newest-updated first")
    func sessionsSortedByRecency() async throws {
        let older = Self.makeSession(title: "Older", updatedAt: Self.t0)
        let newer = Self.makeSession(title: "Newer", updatedAt: Self.t0.addingTimeInterval(60))
        let repository = InMemorySessionRepository(sessions: [older, newer])

        let all = try await repository.allSessions()

        #expect(all.map(\.title) == ["Newer", "Older"])
    }

    @Test("saving an existing id replaces rather than duplicates")
    func saveReplacesByID() async throws {
        let repository = InMemorySessionRepository()
        let session = Self.makeSession(title: "Draft", updatedAt: Self.t0)
        try await repository.create(session)

        try await repository.save(session.withTitle("Renamed", at: Self.t0))

        let all = try await repository.allSessions()
        #expect(all.count == 1)
        #expect(all[0].title == "Renamed")
    }

    @Test("creating an id that already exists does not move its host")
    func createDoesNotRebind() async throws {
        let repository = InMemorySessionRepository()
        let session = Self.makeSession(title: "Bound to A", updatedAt: Self.t0, hostID: Self.hostA)
        try await repository.create(session)

        let impostor = Session(
            id: session.id,
            hostID: Self.hostB,
            backendID: session.backendID,
            title: "Claimed by B",
            createdAt: session.createdAt,
            updatedAt: session.updatedAt
        )
        try await repository.create(impostor)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.hostID == Self.hostA)
        #expect(loaded.title == "Bound to A")
    }

    @Test("a save carrying a different host does not move the session")
    func saveCannotRebindHost() async throws {
        let repository = InMemorySessionRepository()
        let session = Self.makeSession(title: "Stays", updatedAt: Self.t0, hostID: Self.hostA)
        try await repository.create(session)

        let moved = Session(
            id: session.id,
            hostID: Self.hostB,
            backendID: session.backendID,
            title: "Renamed",
            createdAt: session.createdAt,
            updatedAt: Self.t0.addingTimeInterval(30)
        )
        try await repository.save(moved)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.hostID == Self.hostA)
        #expect(loaded.title == "Renamed")
    }

    @Test("queries are host-scoped — the same backend name on two hosts stays apart")
    func queriesAreHostScoped() async throws {
        let onA = Self.makeSession(title: "A/claude", updatedAt: Self.t0, hostID: Self.hostA, backendID: "claude")
        let onB = Self.makeSession(title: "B/claude", updatedAt: Self.t0, hostID: Self.hostB, backendID: "claude")
        let repository = InMemorySessionRepository(sessions: [onA, onB])

        let matched = try await repository.sessions(
            matching: SessionQuery(hostID: Self.hostA, backendID: "claude")
        )

        #expect(matched.map(\.title) == ["A/claude"])
    }

    @Test("delete removes the session")
    func deleteRemoves() async throws {
        let session = Self.makeSession(title: "Doomed", updatedAt: Self.t0)
        let repository = InMemorySessionRepository(sessions: [session])

        try await repository.delete(id: session.id)

        #expect(try await repository.session(id: session.id) == nil)
        #expect(try await repository.allSessions().isEmpty)
    }

    @Test("deleting an unknown id is a no-op")
    func deleteUnknownIsNoOp() async throws {
        let session = Self.makeSession(title: "Kept", updatedAt: Self.t0)
        let repository = InMemorySessionRepository(sessions: [session])

        try await repository.delete(id: UUID())

        #expect(try await repository.allSessions().count == 1)
    }

    @Test("backends come back in alphabetical order, scoped to their host")
    func backendsSortedByName() async throws {
        let repository = InMemorySessionRepository()
        try await repository.save(Self.makeBackend(name: "Zeta"), on: Self.hostA)
        try await repository.save(Self.makeBackend(name: "Alpha"), on: Self.hostA)
        try await repository.save(Self.makeBackend(name: "Elsewhere"), on: Self.hostB)

        let names = try await repository.backends(ofHost: Self.hostA).map(\.displayName)

        #expect(names == ["Alpha", "Zeta"])
    }

    @Test("the same backend name on two hosts is two backends, not one")
    func sameBackendNameOnTwoHosts() async throws {
        let repository = InMemorySessionRepository()
        try await repository.save(AgentBackend(id: "claude", displayName: "On Studio"), on: Self.hostA)
        try await repository.save(AgentBackend(id: "claude", displayName: "On MacBook"), on: Self.hostB)

        #expect(try await repository.backends(ofHost: Self.hostA).map(\.displayName) == ["On Studio"])
        #expect(try await repository.backends(ofHost: Self.hostB).map(\.displayName) == ["On MacBook"])
    }

    @Test("deleteBackend removes only the requested backend on the requested host")
    func deleteBackendIsScoped() async throws {
        let repository = InMemorySessionRepository()
        try await repository.save(Self.makeBackend(name: "Doomed"), on: Self.hostA)
        try await repository.save(Self.makeBackend(name: "Kept"), on: Self.hostA)
        try await repository.save(Self.makeBackend(name: "Doomed"), on: Self.hostB)

        try await repository.deleteBackend(id: "doomed", on: Self.hostA)

        #expect(try await repository.backends(ofHost: Self.hostA).map(\.displayName) == ["Kept"])
        // The same-named backend on the other machine is untouched (FR-029).
        #expect(try await repository.backends(ofHost: Self.hostB).map(\.displayName) == ["Doomed"])
    }
}
