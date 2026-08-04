import Foundation
import Testing

@testable import BridgeCore

/// **The shared sample.**
///
/// `Packages/TransportKit/Tests/TransportKitTests/Fixtures/chat-stream.sse` was
/// written by the iOS side, by hand, as what it *believes* this bridge emits.
/// Until now nothing on this side had ever read it: two fixtures in two layers,
/// no sample in common, both suites green. That is the shape ADR-0001 exists to
/// prevent — "两侧各自照契约实现、各自全绿，而端到端从未被执行过".
///
/// **Not a byte comparison.** The fixture is deliberately adversarial: it
/// carries an invented event name, a `: keep-alive` comment, and fields this
/// bridge does not send (`id`, `started_at`, `session_id`). Demanding identical
/// bytes would fail on all of those and prove nothing about compatibility.
///
/// What is compared is the thing a divergence would actually break: **the event
/// names and the key names**. If iOS reads `call_id` and this encoder emits
/// `callId`, both sides stay green forever and the feature silently never
/// works. That is discoverable today, without a server, without the network,
/// and without waiting for the iOS deadlock to be fixed.
///
/// The file is read rather than copied. A copy would drift the first time iOS
/// edited theirs, and a stale copy that still passes is worse than no test.
@Suite("SSEEncoder — agreement with the iOS fixture")
struct SharedFixtureTests {
    /// Every named event in the fixture must be one this encoder can produce
    /// under the same name.
    ///
    /// The exception is deliberate: the fixture includes
    /// `x-localis-invented-later`, which exists to prove the client skips names
    /// it does not know (FR-010). A bridge that emitted it would be the bug.
    @Test("the fixture's event names are names this encoder emits")
    func eventNamesAgree() throws {
        let frames = try Self.fixtureFrames()
        let emitted = Set(Self.samples.compactMap { Self.name(of: SSEEncoder.encode($0)) })

        let expected = Set(frames.compactMap(\.event))
            .subtracting(["x-localis-invented-later"])

        let missing = expected.subtracting(emitted)
        #expect(missing.isEmpty, "iOS expects event names this bridge never sends: \(missing.sorted())")
    }

    /// **The load-bearing check.**
    ///
    /// For each event kind, every key the iOS fixture carries must be a key
    /// this encoder emits — or be on the list of keys iOS is known to treat as
    /// optional, each with the reason written down. A key that is neither is a
    /// real divergence: iOS reads a name that never arrives.
    @Test("each event's key names match what iOS expects", arguments: Self.comparableKinds)
    func keyNamesAgree(kind: Kind) throws {
        let frames = try Self.fixtureFrames()

        guard let expected = frames.first(where: { $0.event == kind.eventName }) else {
            Issue.record("the fixture has no \(kind.eventName ?? "unnamed") frame to compare against")
            return
        }

        let mine = try #require(Self.keys(of: SSEEncoder.encode(kind.sample)))
        let theirs = try #require(expected.keys)

        let missing = theirs.subtracting(mine).subtracting(Self.optionalKeys)
        #expect(
            missing.isEmpty,
            "iOS's \(kind.eventName ?? "chunk") frame carries keys this encoder never emits: \(missing.sorted())"
        )
    }

    /// `seq` sits at the top level of *every* frame, extension and chunk alike.
    ///
    /// The client reads it before it knows what kind of frame it holds, so a
    /// `seq` nested inside a payload would make resume work for extensions and
    /// silently not for content — the half that matters most.
    @Test("every frame carries seq at the top level")
    func seqIsAlwaysTopLevel() throws {
        for sample in Self.samples {
            guard case .done = sample.event else {
                let keys = try #require(Self.keys(of: SSEEncoder.encode(sample)))
                #expect(keys.contains("seq"), "a frame went out without a top-level seq")
                continue
            }
        }
    }

    /// The sentinel is a literal, compared by the client as text.
    ///
    /// Taken from the fixture rather than written here: writing `[DONE]` in
    /// this file again would only prove this file agrees with itself.
    @Test("the [DONE] sentinel matches the fixture's")
    func doneSentinelAgrees() throws {
        let frames = try Self.fixtureFrames()
        let theirs = try #require(frames.last { $0.event == nil }?.raw)

        #expect(SSEEncoder.encode(SequencedEvent(seq: nil, event: .done)).contains(theirs))
    }

    // MARK: - Kinds

    /// One event kind, with a sample this encoder can produce.
    struct Kind: Sendable, CustomTestStringConvertible {
        let eventName: String?
        let sample: SequencedEvent

        var testDescription: String { eventName ?? "chunk" }
    }

    static let comparableKinds: [Kind] = [
        Kind(
            eventName: "x-localis-tool-call",
            sample: SequencedEvent(seq: 5, event: .toolCall(ToolCallEvent(
                callID: "c-7",
                phase: .end,
                tool: "Bash",
                summary: "git status",
                outcome: .ok,
                durationMs: 840
            )))
        ),
        Kind(
            eventName: "x-localis-approval-required",
            sample: SequencedEvent(seq: 8, event: .approvalRequired(ApprovalEvent(
                approvalID: "a-123",
                tool: "Write",
                summary: "write foo.swift"
            )))
        ),
        Kind(
            eventName: "x-localis-session-status",
            sample: SequencedEvent(seq: 1, event: .sessionStatus("thinking"))
        ),
        Kind(
            eventName: "x-localis-turn-end",
            sample: SequencedEvent(seq: 11, event: .turnEnd(TurnEndEvent(
                turnID: "t-9",
                outcome: .completed,
                toolCallsCompleted: 1
            )))
        ),
    ]

    /// Everything this encoder can emit, for the whole-set checks.
    static let samples: [SequencedEvent] =
        comparableKinds.map(\.sample) + [
            SequencedEvent(seq: 2, event: .delta("He")),
            SequencedEvent(seq: 9, event: .finished(reason: "stop")),
            SequencedEvent(seq: 10, event: .usage(TokenUsage(
                promptTokens: 1200,
                completionTokens: 340,
                totalTokens: 1540
            ))),
            SequencedEvent(seq: 7, event: .telemetry(["context_used": .number(0.42)])),
            SequencedEvent(seq: nil, event: .done),
        ]

    /// Keys iOS's fixture carries that this bridge deliberately does not send.
    ///
    /// Listed explicitly rather than by loosening the comparison, so adding one
    /// is a decision someone made rather than a check quietly getting weaker.
    ///
    /// - `session_id`: envelope framing the client already knows — it sent the
    ///   session id in the request header. `StreamEventMapper` lists it under
    ///   `envelopeKeys` and strips it before reading a payload.
    /// - `id`: OpenAI's per-completion identifier. The client never reads it,
    ///   and this bridge's identifier for a turn is `turn_id`.
    /// - `started_at`: a wall-clock timestamp on tool calls. Not read by the
    ///   mapper, which reports `duration_ms` on the `end` frame instead.
    static let optionalKeys: Set<String> = ["session_id", "id", "started_at"]

    // MARK: - Reading the fixture

    struct FixtureFrame {
        let event: String?
        let raw: String
        let keys: Set<String>?
    }

    /// The iOS fixture, parsed into frames.
    private static func fixtureFrames() throws -> [FixtureFrame] {
        let text = try String(contentsOf: fixtureURL, encoding: .utf8)

        return text.components(separatedBy: "\n\n").compactMap { block -> FixtureFrame? in
            var name: String?
            var data: String?

            for line in block.split(separator: "\n") {
                // `:` opens an SSE comment — the fixture's `: keep-alive`.
                // Skipped rather than parsed, which is what the client does.
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
                if line.hasPrefix("data: ") { data = String(line.dropFirst(6)) }
            }

            guard let data else { return nil }

            let object = try? JSONSerialization.jsonObject(with: Data(data.utf8))
            let keys = (object as? [String: Any]).map { Set($0.keys) }

            return FixtureFrame(event: name, raw: data, keys: keys)
        }
    }

    /// Located relative to this file, not by a hard-coded absolute path.
    ///
    /// `bridge/` is a sibling of `Packages/` in the same repository, so the
    /// path is stable — and if the fixture ever moves, this test fails loudly
    /// rather than skipping.
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)                     // .../bridge/Tests/BridgeCoreTests/<this>
            .deletingLastPathComponent()                    // BridgeCoreTests
            .deletingLastPathComponent()                    // Tests
            .deletingLastPathComponent()                    // bridge
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("Packages/TransportKit/Tests/TransportKitTests/Fixtures/chat-stream.sse")
    }

    // MARK: - Reading this encoder's output

    /// The `event:` name of an encoded frame, or nil when unnamed.
    private static func name(of frame: String) -> String? {
        frame.split(separator: "\n")
            .first { $0.hasPrefix("event: ") }
            .map { String($0.dropFirst(7)) }
    }

    /// The top-level keys of an encoded frame's JSON payload.
    private static func keys(of frame: String) -> Set<String>? {
        guard
            let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
            let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)),
            let fields = object as? [String: Any]
        else {
            return nil
        }
        return Set(fields.keys)
    }
}
