import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// Migration must never cost the user a conversation (FR-038, SC-008).
///
/// These run against the real container: legacy rows are written with no host
/// attribution, migration runs, and the assertion is always the same — the same
/// number of sessions and messages come out as went in.
@Suite("Host attribution migration")
struct HostAttributionMigrationTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private static let hostB = HostID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    /// A session as it existed before Amendment A: no machine to name.
    ///
    /// `Session.hostID` is non-optional, so the value carries the unattributed
    /// marker; `createUnattributed` writes the row with a null host, which is
    /// the actual on-disk legacy shape.
    private static func legacySession(title: String) -> Session {
        Session(
            id: UUID(),
            hostID: .unattributed,
            backendID: "claude",
            title: title,
            messages: [Message(id: UUID(), role: .user, text: "hi", createdAt: t0)],
            createdAt: t0,
            updatedAt: t0
        )
    }

    private static func attributedSession(title: String, on hostID: HostID) -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: "claude",
            title: title,
            messages: [Message(id: UUID(), role: .user, text: "hi", createdAt: t0)],
            createdAt: t0,
            updatedAt: t0
        )
    }

    /// Seeds sessions with no host — the shape of data written before
    /// Amendment A existed.
    private static func seedLegacy(
        _ repository: SwiftDataSessionRepository,
        titles: [String]
    ) async throws -> [Session] {
        let sessions = titles.map { legacySession(title: $0) }
        for session in sessions {
            try await repository.createUnattributed(session)
        }
        return sessions
    }

    @Test("one paired host backfills every legacy session and loses nothing")
    func singleHostBackfill() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let seeded = try await Self.seedLegacy(repository, titles: ["One", "Two", "Three"])

        let report = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])

        #expect(report.attributed == 3)
        #expect(report.orphaned == 0)
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostA)).count == 3)
        #expect(try await repository.allSessions().count == seeded.count)
    }

    @Test("no paired host leaves every legacy session unattributed and deletes none")
    func noHostOrphansAll() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        _ = try await Self.seedLegacy(repository, titles: ["One", "Two"])

        let report = try await repository.migrateHostAttribution(pairedHosts: [])

        #expect(report.attributed == 0)
        #expect(report.orphaned == 2)
        #expect(try await repository.sessions(matching: .unattributed).count == 2)
        #expect(try await repository.allSessions().count == 2)
    }

    @Test("ambiguous hosts leave sessions unattributed rather than guess, and delete nothing")
    func ambiguousHostsOrphan() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        _ = try await Self.seedLegacy(repository, titles: ["One", "Two"])

        let report = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA, Self.hostB])

        #expect(report.orphaned == 2)
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostA)).isEmpty)
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostB)).isEmpty)
        #expect(try await repository.allSessions().count == 2)
    }

    @Test("an unattributable session is readable but never sendable")
    func unattributedSessionIsReadOnly() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        _ = try await Self.seedLegacy(repository, titles: ["Kept"])

        _ = try await repository.migrateHostAttribution(pairedHosts: [])

        let loaded = try #require(try await repository.sessions(matching: .unattributed).first)
        #expect(loaded.hostID == .unattributed)
        #expect(loaded.status == .orphaned)
        #expect(loaded.canSend == false)
        // Read-only, not gone: the transcript is intact (FR-036).
        #expect(loaded.messages.count == 1)
    }

    @Test("migration never drops a message")
    func messagesSurviveMigration() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        _ = try await Self.seedLegacy(repository, titles: ["One", "Two", "Three"])
        let before = try await repository.storedMessageCount()

        _ = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])

        #expect(try await repository.storedMessageCount() == before)
        #expect(before == 3)
    }

    @Test("migration leaves already-attributed sessions on their own host")
    func attributedSessionsAreNotReassigned() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.create(Self.attributedSession(title: "Already on B", on: Self.hostB))
        _ = try await Self.seedLegacy(repository, titles: ["Legacy"])

        let report = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])

        #expect(report.attributed == 1)
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostB)).map(\.title) == ["Already on B"])
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostA)).map(\.title) == ["Legacy"])
    }

    @Test("a backfilled session is fully usable, not left read-only")
    func backfilledSessionIsNotOrphaned() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        _ = try await Self.seedLegacy(repository, titles: ["Recovered"])

        _ = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])

        let loaded = try #require(try await repository.sessions(matching: SessionQuery(hostID: Self.hostA)).first)
        #expect(loaded.hostID == Self.hostA)
        #expect(loaded.status != .orphaned)
    }

    @Test("running migration twice changes nothing the second time")
    func migrationIsIdempotent() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        _ = try await Self.seedLegacy(repository, titles: ["One", "Two"])

        _ = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])
        let second = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])

        #expect(second.attributed == 0)
        #expect(second.orphaned == 0)
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostA)).count == 2)
    }

    @Test("adopting an unattributed session attaches it to the chosen machine")
    func adoptionAttachesUnattributed() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let seeded = try await Self.seedLegacy(repository, titles: ["Chosen"])
        _ = try await repository.migrateHostAttribution(pairedHosts: [])

        try await repository.adopt(sessionIDs: seeded.map(\.id), on: Self.hostA)

        let loaded = try #require(try await repository.session(id: seeded[0].id))
        #expect(loaded.hostID == Self.hostA)
        #expect(loaded.status != .orphaned)
        #expect(try await repository.sessions(matching: .unattributed).isEmpty)
    }

    @Test("adoption cannot steal a session that already has a machine")
    func adoptionSkipsAttributedSessions() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let onB = Self.attributedSession(title: "Owned by B", on: Self.hostB)
        try await repository.create(onB)

        try await repository.adopt(sessionIDs: [onB.id], on: Self.hostA)

        let loaded = try #require(try await repository.session(id: onB.id))
        #expect(loaded.hostID == Self.hostB)
    }

    @Test("migrating an empty store is a no-op, not a failure")
    func emptyStoreMigrates() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)

        let report = try await repository.migrateHostAttribution(pairedHosts: [Self.hostA])

        #expect(report.attributed == 0)
        #expect(report.orphaned == 0)
    }
}
