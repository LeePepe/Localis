import Foundation
import Testing

@testable import LocalisModels

@Suite("Message")
struct MessageTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("appending returns a new value and leaves the original untouched")
    func appendingIsImmutable() {
        let original = Message(
            id: UUID(),
            role: .assistant,
            text: "Hel",
            createdAt: Self.fixedDate,
            status: .streaming
        )

        let appended = original.appending("lo")

        #expect(original.text == "Hel")
        #expect(appended.text == "Hello")
        #expect(appended.id == original.id)
        #expect(appended.status == .streaming)
    }

    @Test("withStatus preserves identity and text")
    func withStatusPreservesContent() {
        let original = Message(
            id: UUID(),
            role: .assistant,
            text: "done",
            createdAt: Self.fixedDate,
            status: .streaming
        )

        let completed = original.withStatus(.complete)

        #expect(completed.status == .complete)
        #expect(completed.text == "done")
        #expect(original.status == .streaming)
    }
}

@Suite("Session")
struct SessionTests {
    private static let created = Date(timeIntervalSince1970: 1_700_000_000)
    private static let updated = Date(timeIntervalSince1970: 1_700_000_060)

    private static func makeSession(messages: [Message] = []) -> Session {
        Session(
            id: UUID(),
            backendID: "test-backend",
            title: "Test",
            messages: messages,
            createdAt: created,
            updatedAt: created
        )
    }

    @Test("appending adds the message and advances updatedAt")
    func appendingAdvancesTimestamp() {
        let session = Self.makeSession()
        let message = Message(id: UUID(), role: .user, text: "hi", createdAt: Self.updated)

        let next = session.appending(message, at: Self.updated)

        #expect(session.messages.isEmpty)
        #expect(next.messages.count == 1)
        #expect(next.updatedAt == Self.updated)
        #expect(next.lastMessage?.text == "hi")
    }

    @Test("replacing swaps a message in place by id")
    func replacingSwapsByID() {
        let message = Message(id: UUID(), role: .assistant, text: "par", createdAt: Self.created, status: .streaming)
        let session = Self.makeSession(messages: [message])

        let next = session.replacing(message.appending("tial"), at: Self.updated)

        #expect(next.messages.count == 1)
        #expect(next.messages[0].text == "partial")
        #expect(session.messages[0].text == "par")
    }

    @Test("replacing an unknown id is a no-op")
    func replacingUnknownIDIsNoOp() {
        let session = Self.makeSession(messages: [
            Message(id: UUID(), role: .user, text: "hi", createdAt: Self.created)
        ])
        let stranger = Message(id: UUID(), role: .assistant, text: "nope", createdAt: Self.updated)

        let next = session.replacing(stranger, at: Self.updated)

        #expect(next == session)
    }
}

@Suite("AgentBackend")
struct AgentBackendTests {
    private static func makeBackend() -> AgentBackend {
        AgentBackend(
            id: "claude-sonnet",
            displayName: "MacBook Claude",
            capabilities: ["streaming", "tools"]
        )
    }

    @Test("withDisplayName keeps identity and changes only the label")
    func withDisplayNameIsImmutable() {
        let original = Self.makeBackend()

        let renamed = original.withDisplayName("Studio Claude")

        #expect(renamed.id == original.id)
        #expect(renamed.capabilities == original.capabilities)
        #expect(renamed.displayName == "Studio Claude")
        #expect(original.displayName == "MacBook Claude")
    }

    @Test("supports reads the advertised capability set")
    func supportsReadsCapabilities() {
        // Constitution principle IV: a feature check asks what a backend *can
        // do*, never what it *is*. If this ever becomes a switch over a closed
        // set of backend names, adding a sixth agent needs an App Store release.
        let backend = Self.makeBackend()

        #expect(backend.supports("streaming"))
        #expect(backend.supports("tools"))
        #expect(!backend.supports("resume"))
    }

    @Test("a backend advertising nothing supports nothing")
    func emptyCapabilitiesSupportNothing() {
        let bare = AgentBackend(id: "bare", displayName: "Bare")

        #expect(bare.capabilities.isEmpty)
        #expect(!bare.supports("streaming"))
    }
}

@Suite("LocalisError")
struct LocalisErrorTests {
    @Test("every error carries a user-facing message")
    func allErrorsHaveUserMessages() {
        let cases: [LocalisError] = [
            .unreachable, .connectionLost, .malformedResponse,
            .unauthorized, .invalidInput(field: "endpoint"), .cancelled
        ]

        for error in cases {
            #expect(!error.userMessage.isEmpty)
        }
    }
}
