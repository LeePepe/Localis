import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// The SwiftData-backed repository, exercised entirely in memory.
///
/// Covers what the store owes the rest of the app: CRUD, host-scoped retrieval,
/// concurrent writes, and survival across a container teardown (the "kill the
/// app and reopen" case, SC-008).
@Suite("SwiftDataSessionRepository")
struct SwiftDataSessionRepositoryTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private static let hostB = HostID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    private static func makeSession(
        id: UUID = UUID(),
        hostID: HostID = hostA,
        backendID: String = "claude",
        title: String = "Session",
        messages: [Message] = [],
        updatedAt: Date = t0
    ) -> Session {
        Session(
            id: id,
            hostID: hostID,
            backendID: backendID,
            title: title,
            messages: messages,
            createdAt: t0,
            updatedAt: updatedAt
        )
    }

    private static func makeMessage(
        text: String,
        role: MessageRole = .assistant,
        status: MessageStatus = .complete
    ) -> Message {
        Message(id: UUID(), role: role, text: text, createdAt: t0, status: status)
    }

    // MARK: - CRUD

    @Test("a created session reads back with its content intact")
    func createAndRead() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(title: "First", messages: [Self.makeMessage(text: "hello")])

        try await repository.create(session)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.title == "First")
        #expect(loaded.hostID == Self.hostA)
        #expect(loaded.messages.map(\.text) == ["hello"])
    }

    @Test("saving an existing session updates it rather than duplicating")
    func saveUpdatesInPlace() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(title: "Draft")
        try await repository.create(session)

        try await repository.save(session.withTitle("Renamed", at: Self.t0))

        let all = try await repository.sessions(matching: SessionQuery(hostID: Self.hostA))
        #expect(all.count == 1)
        #expect(all[0].title == "Renamed")
    }

    @Test("appended messages persist in order")
    func messagesKeepOrder() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        var session = Self.makeSession()
        try await repository.create(session)

        for (offset, text) in ["one", "two", "three"].enumerated() {
            let message = Message(
                id: UUID(),
                role: .assistant,
                text: text,
                createdAt: Self.t0.addingTimeInterval(Double(offset)),
                status: .complete
            )
            session = session.appending(message, at: Self.t0.addingTimeInterval(Double(offset)))
            try await repository.save(session)
        }

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.messages.map(\.text) == ["one", "two", "three"])
    }

    @Test("a streaming message is superseded, not duplicated")
    func streamingReplacesRatherThanAppends() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let partial = Message(id: UUID(), role: .assistant, text: "He", createdAt: Self.t0, status: .streaming)
        var session = Self.makeSession(messages: [partial])
        try await repository.create(session)

        session = session.replacing(partial.appending("llo").withStatus(.complete), at: Self.t0)
        try await repository.save(session)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.messages.count == 1)
        #expect(loaded.messages[0].text == "Hello")
        #expect(loaded.messages[0].status == .complete)
    }

    @Test("delete removes the session and its messages")
    func deleteCascades() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(messages: [Self.makeMessage(text: "gone")])
        try await repository.create(session)

        try await repository.delete(id: session.id)

        #expect(try await repository.session(id: session.id) == nil)
        #expect(try await repository.storedMessageCount() == 0)
    }

    @Test("deleting an unknown id is a no-op, not an error")
    func deleteUnknownIsNoOp() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.create(Self.makeSession())

        try await repository.delete(id: UUID())

        #expect(try await repository.allSessions().count == 1)
    }

    @Test("sessions come back newest-updated first")
    func sortedByRecency() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.create(Self.makeSession(title: "Older", updatedAt: Self.t0))
        try await repository.create(
            Self.makeSession(title: "Newer", updatedAt: Self.t0.addingTimeInterval(60))
        )

        let titles = try await repository.allSessions().map(\.title)

        #expect(titles == ["Newer", "Older"])
    }

    // MARK: - Host scoping (the composite-key red line)

    @Test("a host-scoped query returns only that host's sessions")
    func queryIsHostScoped() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.create(Self.makeSession(hostID: Self.hostA, title: "On A"))
        try await repository.create(Self.makeSession(hostID: Self.hostB, title: "On B"))

        let onA = try await repository.sessions(matching: SessionQuery(hostID: Self.hostA))

        #expect(onA.map(\.title) == ["On A"])
    }

    @Test("the same backend name on two hosts never cross-matches")
    func sameBackendNameOnTwoHostsStaysSeparate() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.create(
            Self.makeSession(hostID: Self.hostA, backendID: "claude", title: "A/claude")
        )
        try await repository.create(
            Self.makeSession(hostID: Self.hostB, backendID: "claude", title: "B/claude")
        )

        let onA = try await repository.sessions(matching: SessionQuery(hostID: Self.hostA, backendID: "claude"))
        let onB = try await repository.sessions(matching: SessionQuery(hostID: Self.hostB, backendID: "claude"))

        #expect(onA.map(\.title) == ["A/claude"])
        #expect(onB.map(\.title) == ["B/claude"])
    }

    @Test("host attribution is fixed at creation and re-creating cannot move it")
    func hostBindingIsImmutable() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(hostID: Self.hostA, title: "Bound to A")
        try await repository.create(session)

        // A value claiming the same id on another machine must not migrate it (FR-030).
        let impostor = Session(
            id: session.id,
            hostID: Self.hostB,
            backendID: session.backendID,
            title: session.title,
            messages: session.messages,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt
        )
        try await repository.create(impostor)

        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostB)).isEmpty)
        #expect(try await repository.sessions(matching: SessionQuery(hostID: Self.hostA)).count == 1)
    }

    @Test("a save carrying a different host does not move the session")
    func saveCannotRebindHost() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(hostID: Self.hostA, title: "Stays on A")
        try await repository.create(session)

        let moved = Session(
            id: session.id,
            hostID: Self.hostB,
            backendID: "codex",
            title: "Renamed",
            messages: session.messages,
            createdAt: session.createdAt,
            updatedAt: Self.t0.addingTimeInterval(30)
        )
        try await repository.save(moved)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.hostID == Self.hostA)
        // The mutable fields did land — only the binding is refused.
        #expect(loaded.title == "Renamed")
        #expect(loaded.backendID == "codex")
    }

    // MARK: - Unpairing keeps history

    @Test("unpairing a host marks its sessions orphaned instead of deleting them")
    func unpairOrphansRatherThanDeletes() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.create(Self.makeSession(hostID: Self.hostA, title: "History"))
        try await repository.create(Self.makeSession(hostID: Self.hostB, title: "Elsewhere"))

        try await repository.orphanSessions(ofHost: Self.hostA)

        // The binding survives — FR-030 — so the session is still found by host.
        let onA = try await repository.sessions(matching: SessionQuery(hostID: Self.hostA))
        #expect(onA.map(\.title) == ["History"])
        #expect(onA[0].status == .orphaned)
        #expect(onA[0].canSend == false)
        // The other machine is untouched.
        let onB = try await repository.sessions(matching: SessionQuery(hostID: Self.hostB))
        #expect(onB.count == 1)
        #expect(onB[0].status != .orphaned)
    }

    @Test("orphaned history is still fully readable")
    func orphanedHistoryStaysReadable() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(messages: [Self.makeMessage(text: "still here")])
        try await repository.create(session)

        try await repository.orphanSessions(ofHost: Self.hostA)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.messages.map(\.text) == ["still here"])
        #expect(loaded.status == .orphaned)
    }

    @Test("re-pairing a host reactivates its orphaned sessions")
    func repairingReactivatesOrphans() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession(title: "Reclaimed")
        try await repository.create(session)
        try await repository.orphanSessions(ofHost: Self.hostA)

        try await repository.reactivateSessions(ofHost: Self.hostA)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.title == "Reclaimed")
        #expect(loaded.status != .orphaned)
    }

    @Test("reactivating one host leaves another host's orphans orphaned")
    func reactivationIsHostScoped() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let onB = Self.makeSession(hostID: Self.hostB, title: "Still unpaired")
        try await repository.create(Self.makeSession(hostID: Self.hostA, title: "Back"))
        try await repository.create(onB)
        try await repository.orphanSessions(ofHost: Self.hostA)
        try await repository.orphanSessions(ofHost: Self.hostB)

        try await repository.reactivateSessions(ofHost: Self.hostA)

        let loaded = try #require(try await repository.session(id: onB.id))
        #expect(loaded.status == .orphaned)
    }

    // MARK: - Resume cursors

    @Test("a resume cursor survives being stored and read back")
    func cursorRoundTrips() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let message = Self.makeMessage(text: "partial", status: .streaming)
        let session = Self.makeSession(messages: [message])
        try await repository.create(session)

        try await repository.recordTurn(
            messageID: message.id,
            state: .detached,
            cursor: ResumeCursor(turnID: "turn-9", lastSeq: 42)
        )

        let reconciliation = try await repository.reconcile(messageID: message.id)
        #expect(reconciliation == .stillRunning(ResumeCursor(turnID: "turn-9", lastSeq: 42)))
    }

    @Test("a turn with no cursor reconciles as lost rather than resumable")
    func turnWithoutCursorIsLost() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let message = Self.makeMessage(text: "partial", status: .streaming)
        try await repository.create(Self.makeSession(messages: [message]))

        try await repository.recordTurn(messageID: message.id, state: .interrupted, cursor: nil)

        #expect(try await repository.reconcile(messageID: message.id) == .lost)
    }

    @Test("reconciling an unknown message reports settled, not a crash")
    func reconcileUnknownMessage() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)

        #expect(try await repository.reconcile(messageID: UUID()) == .settled)
    }

    @Test("pending turns separate the resumable from the lost")
    func pendingTurnsReportsBoth() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let live = Self.makeMessage(text: "live", status: .streaming)
        let dead = Self.makeMessage(text: "dead", status: .streaming)
        try await repository.create(Self.makeSession(messages: [live, dead]))

        try await repository.recordTurn(
            messageID: live.id,
            state: .detached,
            cursor: ResumeCursor(turnID: "turn-1", lastSeq: 7)
        )
        try await repository.recordTurn(messageID: dead.id, state: .streaming, cursor: nil)

        let pending = try await repository.pendingTurns()
        let outcomes = Dictionary(uniqueKeysWithValues: pending.map { ($0.messageID, $0.outcome) })

        #expect(outcomes[live.id] == .stillRunning(ResumeCursor(turnID: "turn-1", lastSeq: 7)))
        #expect(outcomes[dead.id] == .lost)
        // Only the lost one may be retried — a live turn must never offer it,
        // or the host ends up running the same work twice (Amendment C §1.5).
        #expect(outcomes[live.id]?.allowsRetry == false)
        #expect(outcomes[dead.id]?.allowsRetry == true)
    }

    // MARK: - Concurrency

    @Test("concurrent writes to different sessions all land")
    func concurrentWritesToDistinctSessions() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let sessions = (0..<20).map { Self.makeSession(title: "S\($0)") }

        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { try? await repository.create(session) }
            }
        }

        #expect(try await repository.allSessions().count == 20)
    }

    @Test("concurrent appends to one session do not lose messages")
    func concurrentAppendsToOneSession() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let session = Self.makeSession()
        try await repository.create(session)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let message = Message(
                        id: UUID(),
                        role: .assistant,
                        text: "m\(index)",
                        createdAt: Self.t0.addingTimeInterval(Double(index)),
                        status: .complete
                    )
                    try? await repository.append(message, toSession: session.id, at: Self.t0)
                }
            }
        }

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.messages.count == 20)
        #expect(Set(loaded.messages.map(\.text)).count == 20)
    }

    // MARK: - Restart recovery

    @Test("sessions and messages survive a new repository over the same store")
    func survivesRepositoryRecreation() async throws {
        let store = try SessionStoreContainer.inMemory()
        let session = Self.makeSession(title: "Persisted", messages: [Self.makeMessage(text: "body")])

        let writer = SwiftDataSessionRepository(container: store)
        try await writer.create(session)

        // A fresh repository over the same container — what a relaunch sees.
        let reader = SwiftDataSessionRepository(container: store)
        let loaded = try #require(try await reader.session(id: session.id))

        #expect(loaded.title == "Persisted")
        #expect(loaded.hostID == Self.hostA)
        #expect(loaded.messages.map(\.text) == ["body"])
        #expect(try await reader.sessions(matching: SessionQuery(hostID: Self.hostA)).count == 1)
    }

    @Test("a restored session comes back disconnected, never ready to send")
    func restoredSessionIsNotSendable() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        // Written while the link was live…
        let session = Session(
            id: UUID(),
            hostID: Self.hostA,
            backendID: "claude",
            title: "Was idle",
            createdAt: Self.t0,
            updatedAt: Self.t0,
            status: .idle
        )
        try await repository.create(session)

        // …and read back after a relaunch, when no connection exists yet.
        let loaded = try #require(try await repository.session(id: session.id))

        #expect(loaded.status == .disconnected)
        #expect(loaded.canSend == false)
    }

    @Test("a turn left mid-stream by a killed process is not reported as streaming")
    func killedStreamIsReconciled() async throws {
        let store = try SessionStoreContainer.inMemory()
        let message = Self.makeMessage(text: "half", status: .streaming)

        let writer = SwiftDataSessionRepository(container: store)
        try await writer.create(Self.makeSession(messages: [message]))
        try await writer.recordTurn(
            messageID: message.id,
            state: .detached,
            cursor: ResumeCursor(turnID: "turn-1", lastSeq: 3)
        )

        let afterRelaunch = SwiftDataSessionRepository(container: store)
        let outcome = try await afterRelaunch.reconcile(messageID: message.id)

        #expect(outcome == .stillRunning(ResumeCursor(turnID: "turn-1", lastSeq: 3)))
        #expect(!outcome.allowsRetry)
    }

    // MARK: - Backends

    @Test("backends are stored per host and never collide across hosts")
    func backendsAreHostScoped() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        let onA = AgentBackend(id: "claude", displayName: "Claude on Studio", capabilities: ["streaming"])
        let onB = AgentBackend(id: "claude", displayName: "Claude on MacBook", capabilities: ["streaming"])

        try await repository.save(onA, on: Self.hostA)
        try await repository.save(onB, on: Self.hostB)

        #expect(try await repository.backends(ofHost: Self.hostA).map(\.displayName) == ["Claude on Studio"])
        #expect(try await repository.backends(ofHost: Self.hostB).map(\.displayName) == ["Claude on MacBook"])
    }

    @Test("deleting a backend on one host leaves the same-named one elsewhere")
    func deletingBackendIsHostScoped() async throws {
        let store = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: store)
        try await repository.save(AgentBackend(id: "claude", displayName: "A"), on: Self.hostA)
        try await repository.save(AgentBackend(id: "claude", displayName: "B"), on: Self.hostB)

        try await repository.deleteBackend(id: "claude", on: Self.hostA)

        #expect(try await repository.backends(ofHost: Self.hostA).isEmpty)
        #expect(try await repository.backends(ofHost: Self.hostB).map(\.displayName) == ["B"])
    }
}
