import Foundation
import LocalisModels
import Testing
import TransportKit

@testable import Localis

/// Tests for the milestone-A fake transport.
///
/// A fake gets tested for the same reason the real one does: milestone A's
/// whole claim is "the assembly works, only the far end is fake". If the fake
/// silently yields nothing, the screen looks exactly like a broken stream loop
/// — and the conclusion drawn from the screenshot would be wrong in the
/// direction that costs the most.
@Suite("EchoTransport — the milestone-A fake")
struct EchoTransportTests {
    private static func request(prompt: String) -> TurnRequest {
        TurnRequest(
            backendID: "echo",
            sessionID: UUID(),
            messages: [Message(id: UUID(), role: .user, text: prompt, createdAt: Date())]
        )
    }

    private static func drain(_ stream: TurnStream) async throws -> [StreamEvent] {
        var collected: [StreamEvent] = []
        for try await sequenced in stream.events {
            collected.append(sequenced.event)
        }
        return collected
    }

    @Test("it streams the reply in more than one piece")
    func streamsInPieces() async throws {
        let transport = EchoTransport(chunkDelay: .zero)
        let events = try await Self.drain(transport.send(Self.request(prompt: "hello")))

        let deltas = events.compactMap { event -> String? in
            guard case .delta(let text) = event else { return nil }
            return text
        }
        // More than one delta is the point. A single delta carrying the whole
        // reply would render identically to a non-streaming transport and would
        // prove nothing about the stream loop the screenshot is meant to show.
        #expect(deltas.count > 1, "a one-shot reply demonstrates nothing about streaming")
        #expect(deltas.joined().contains("hello"), "the prompt should come back")
    }

    @Test("it announces that it is fake, in the text the user sees")
    func announcesItself() async throws {
        let transport = EchoTransport(chunkDelay: .zero)
        let events = try await Self.drain(transport.send(Self.request(prompt: "hi")))
        let reply = events.compactMap { event -> String? in
            guard case .delta(let text) = event else { return nil }
            return text
        }.joined()

        // Pinned as a test, not left to the constant, because this is the one
        // property that stops a screenshot of a fake conversation from being
        // read as a real one. Someone tidying the reply text should have to
        // fail a test named for the reason rather than quietly remove it.
        #expect(reply.contains(EchoTransport.displayLabel))
        #expect(reply.contains("No agent is connected"))
    }

    @Test("it ends the turn as completed, with a turn id")
    func endsCompleted() async throws {
        let transport = EchoTransport(chunkDelay: .zero)
        let stream = try await transport.send(Self.request(prompt: "hi"))
        let turnID = try #require(stream.turnID)
        // Prefixed so an id that leaks into a log or a bug report cannot be
        // mistaken for one a real bridge issued.
        #expect(turnID.hasPrefix("echo-"))

        let events = try await Self.drain(stream)
        let ends = events.compactMap { event -> TurnEnd? in
            guard case .turnEnd(let end) = event else { return nil }
            return end
        }
        #expect(ends.count == 1)
        #expect(ends.first?.outcome == .completed)
        // `ChatService` treats `.done` as the close; without it the stream
        // would end by exhaustion and the assistant message would be left
        // looking like it is still arriving.
        #expect(events.last == .done)
    }

    @Test("an empty prompt still produces a reply rather than an empty stream")
    func emptyPromptStillReplies() async throws {
        let transport = EchoTransport(chunkDelay: .zero)
        let events = try await Self.drain(transport.send(Self.request(prompt: "   ")))
        let deltas = events.filter { if case .delta = $0 { return true } else { return false } }
        // An empty stream and a stream that failed look the same on screen.
        #expect(!deltas.isEmpty)
    }
}
