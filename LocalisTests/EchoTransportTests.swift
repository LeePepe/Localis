import Foundation
import LocalisModels
import Testing
import TransportKit

@testable import Localis

/// Tests for the fake transport the app-assembly suites stream through.
///
/// **Why a fixture gets tested.** Three suites use `EchoTransport` as their
/// happy-path far end and then assert something about the app — that a restored
/// session becomes sendable, that a transcript and composer are projected. If
/// the fake silently yielded nothing, those suites would fail in a way that
/// reads as a broken stream loop in `ChatService`, and the investigation would
/// start in the wrong layer. These four tests are what makes the fixture's
/// behaviour a stated thing rather than an assumption held by its users.
///
/// **What changed with milestone B.** This file used to justify itself by the
/// screenshot argument — the fake was the app's real far end and the screen
/// carried a pill saying so, so `announcesItself` was pinning down the one
/// property that stopped a photograph of a fake conversation from being read as
/// a real one. That is no longer the reason: production builds a `BridgeClient`,
/// the pill is gone, and the app target cannot see this type at all. The test
/// below is kept with its claim rewritten to the one that is still true — the
/// text identifies itself in a failure dump — rather than deleted, because the
/// fake's replies still travel in test output.
@Suite("EchoTransport — the app-assembly suites' fake far end")
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
        // reply would render identically to a non-streaming transport, so the
        // suites that use this fixture as their far end would stop exercising
        // `ChatService`'s stream loop without any of them changing colour.
        #expect(deltas.count > 1, "a one-shot reply demonstrates nothing about streaming")
        #expect(deltas.joined().contains("hello"), "the prompt should come back")
    }

    @Test("it names itself in the text it produces")
    func announcesItself() async throws {
        let transport = EchoTransport(chunkDelay: .zero)
        let events = try await Self.drain(transport.send(Self.request(prompt: "hi")))
        let reply = events.compactMap { event -> String? in
            guard case .delta(let text) = event else { return nil }
            return text
        }.joined()

        // Pinned as a test, not left to the constant, because this text travels
        // in failure dumps and bug reports and has to identify itself as a
        // fixture wherever it lands. Someone tidying the reply into something
        // plausible should have to fail a test named for the reason rather than
        // quietly remove it.
        //
        // **This assertion used to carry a stronger claim, and it is worth
        // recording that it no longer does.** Until milestone B the label was
        // rendered in a `StatusPill` above the transcript, and this test was the
        // guard on the property that stopped a *screenshot* of the app from
        // being read as a live Mac. The app no longer uses this transport, so
        // the pill is gone and nothing here says anything about any screen.
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
