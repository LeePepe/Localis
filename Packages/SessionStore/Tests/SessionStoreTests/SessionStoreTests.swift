import Foundation
import Testing

@testable import SessionStore

import LocalisModels

@Suite("InMemorySessionRepository")
struct InMemorySessionRepositoryTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeSession(title: String, updatedAt: Date) -> Session {
        Session(
            id: UUID(),
            backendID: UUID(),
            title: title,
            createdAt: t0,
            updatedAt: updatedAt
        )
    }

    private static func makeBackend(name: String) throws -> AgentBackend {
        AgentBackend(
            id: UUID(),
            kind: .claude,
            name: name,
            endpoint: try #require(URL(string: "http://127.0.0.1:8080"))
        )
    }

    @Test("saving then reading returns the session")
    func saveAndRead() async throws {
        let repository = InMemorySessionRepository()
        let session = Self.makeSession(title: "First", updatedAt: Self.t0)

        try await repository.save(session)

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
        try await repository.save(session)

        try await repository.save(session.withTitle("Renamed", at: Self.t0))

        let all = try await repository.allSessions()
        #expect(all.count == 1)
        #expect(all[0].title == "Renamed")
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

    @Test("backends come back in alphabetical order")
    func backendsSortedByName() async throws {
        let repository = InMemorySessionRepository()
        try await repository.save(try Self.makeBackend(name: "Zeta"))
        try await repository.save(try Self.makeBackend(name: "Alpha"))

        let names = try await repository.allBackends().map(\.name)

        #expect(names == ["Alpha", "Zeta"])
    }

    @Test("deleteBackend removes only the requested backend")
    func deleteBackendIsScoped() async throws {
        let doomed = try Self.makeBackend(name: "Doomed")
        let repository = InMemorySessionRepository(backends: [doomed, try Self.makeBackend(name: "Kept")])

        try await repository.deleteBackend(id: doomed.id)

        #expect(try await repository.allBackends().map(\.name) == ["Kept"])
    }
}
