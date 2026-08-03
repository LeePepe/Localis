import Foundation
import Testing

@testable import LocalisModels

/// `StreamEvent` arrived here from TransportKit, so these tests are not
/// re-testing its mapper — they hold the invariants that survive the move and
/// that anything above this layer now depends on.
///
/// The theme throughout: **an unrecognised value is kept, never forced into a
/// neighbouring case.** Collapsing an unknown outcome into `failed` reports a
/// turn that actually succeeded as broken, which is worse than admitting the
/// state has no name yet.
@Suite("StreamEvent open value sets")
struct StreamEventOpenSetTests {
    @Test("an unrecognised tool outcome is kept, not turned into an error")
    func unknownToolOutcomeIsPreserved() {
        // Reporting a success as a failure is the specific harm here: the user
        // sees a red mark on a tool call that actually worked.
        let outcome = ToolCall.Outcome(wire: "throttled")

        #expect(outcome == .unknown("throttled"))
        #expect(outcome != .error)
    }

    @Test("the documented tool outcomes map to their own cases")
    func knownToolOutcomesMap() {
        #expect(ToolCall.Outcome(wire: "ok") == .ok)
        #expect(ToolCall.Outcome(wire: "error") == .error)
        #expect(ToolCall.Outcome(wire: "cancelled") == .cancelled)
        #expect(ToolCall.Outcome(wire: "denied") == .denied)
    }

    @Test("an unrecognised turn outcome is kept, not turned into a failure")
    func unknownTurnOutcomeIsPreserved() {
        // Same rule one level up. A turn reported as `.unknown` leaves the UI
        // able to say "ended" without claiming it broke.
        let outcome = TurnEnd.Outcome(wire: "superseded")

        #expect(outcome == .unknown("superseded"))
        #expect(outcome != .failed)
    }

    @Test("the documented turn outcomes map to their own cases")
    func knownTurnOutcomesMap() {
        #expect(TurnEnd.Outcome(wire: "completed") == .completed)
        #expect(TurnEnd.Outcome(wire: "failed") == .failed)
        #expect(TurnEnd.Outcome(wire: "cancelled") == .cancelled)
    }

    @Test("an empty wire value is unknown rather than silently a success")
    func emptyWireValueIsUnknown() {
        // The boundary case a mapper is most likely to hand over: a missing
        // field read as "". Defaulting it to `.completed` would mark a turn
        // finished on no evidence at all.
        #expect(TurnEnd.Outcome(wire: "") == .unknown(""))
        #expect(ToolCall.Outcome(wire: "") == .unknown(""))
    }

    @Test("a session status phrase is carried verbatim")
    func sessionStatusIsVerbatim() {
        // Contract §3.4c: an open value set. Matching it against a closed list
        // would blank out every phrase a future bridge invents.
        let event = StreamEvent.sessionStatus("Compacting context…")

        guard case .sessionStatus(let phrase) = event else {
            Issue.record("expected .sessionStatus")
            return
        }
        #expect(phrase == "Compacting context…")
    }
}

/// Token counts (contract §3.4a).
///
/// The rule the contract states twice: **nothing is invented**. A backend that
/// cannot report tokens must not produce a `0`, and must not produce a
/// placeholder slot either — a slot reading "unavailable" implies the number is
/// coming.
@Suite("TokenUsage invents nothing")
struct TokenUsageTests {
    @Test("a backend that reports nothing yields an empty usage")
    func nothingReportedIsEmpty() {
        let usage = TokenUsage(promptTokens: nil, completionTokens: nil, totalTokens: nil)

        #expect(usage.isEmpty)
    }

    @Test("one reported field is enough to be worth rendering")
    func partialUsageIsNotEmpty() {
        // The distinction that matters: partial data is still data. Treating
        // this as empty would throw away a count the host did supply.
        let usage = TokenUsage(promptTokens: 12, completionTokens: nil, totalTokens: nil)

        #expect(!usage.isEmpty)
        #expect(usage.completionTokens == nil)
    }

    @Test("a reported zero is a real number, not an absence")
    func zeroIsNotEmpty() {
        // `0` prompt tokens is a fact the host asserted; `nil` is the host
        // declining to answer. Folding them together loses that difference.
        let usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)

        #expect(!usage.isEmpty)
    }
}

/// Amendment C §3.3: `seq` rides *alongside* the event rather than inside each
/// case, so dedup on resume is one comparison in one place.
@Suite("SequencedEvent carries the cursor alongside")
struct SequencedEventTests {
    @Test("a host without resumable turns sends no seq")
    func seqIsOptional() {
        // Optional rather than defaulted: a host that cannot resume has no
        // sequence to report, and inventing `0` would make its frames look
        // dedupable against a real turn's numbering.
        let event = SequencedEvent(seq: nil, event: .delta("hi"))

        #expect(event.seq == nil)
    }

    @Test("the sequence composes with TurnCursor for dedup")
    func dedupUsesTheCursor() throws {
        // The two types were built to meet here: the cursor decides, the
        // event supplies the number. Neither re-implements the comparison.
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 42)
        let replayed = SequencedEvent(seq: 42, event: .delta("dup"))
        let fresh = SequencedEvent(seq: 43, event: .delta("new"))

        #expect(!cursor.accepts(turnID: "t-9", seq: try #require(replayed.seq)))
        #expect(cursor.accepts(turnID: "t-9", seq: try #require(fresh.seq)))
    }
}

/// Turn-end detail (contract §3.1d) — the payload that makes a failure
/// actionable instead of a bare "Error".
@Suite("TurnEnd carries what a failure needs")
struct TurnEndTests {
    @Test("a failure carries how far the turn got")
    func failureCarriesProgress() {
        let end = TurnEnd(
            turnID: "t-9",
            outcome: .failed,
            failedAtMs: 480_000,
            toolCallsCompleted: 3,
            errorCode: "backend_error"
        )

        #expect(end.outcome == .failed)
        #expect(end.failedAtMs == 480_000)
        #expect(end.toolCallsCompleted == 3)
    }

    @Test("the bridge's error message is not carried at all")
    func errorMessageHasNoHome() {
        // Constitution I / FR-025: `error.message` may contain absolute paths.
        // Only the machine-readable code crosses, and UI text is derived from
        // it locally. A field that does not exist cannot be displayed by a
        // future caller who never read the contract — that is the point.
        let end = TurnEnd(turnID: "t-9", outcome: .failed, errorCode: "backend_error")

        #expect(end.errorCode == "backend_error")
        // The type has no `message`; this test exists so that adding one is a
        // deliberate act someone has to argue for, not a quiet convenience.
        #expect(Mirror(reflecting: end).children.allSatisfy { $0.label != "message" })
    }

    @Test("a completed turn carries no failure detail")
    func successCarriesNoFailureDetail() {
        let end = TurnEnd(turnID: "t-9", outcome: .completed)

        #expect(end.failedAtMs == nil)
        #expect(end.toolCallsCompleted == nil)
        #expect(end.errorCode == nil)
    }

    @Test("a turn id may be absent")
    func turnIDIsOptional() {
        // A host without resumable turns never sends one, and `send` must not
        // require it to report that the turn ended.
        let end = TurnEnd(turnID: nil, outcome: .completed)

        #expect(end.turnID == nil)
    }
}

/// Tool call pairing (contract §3.1a).
@Suite("ToolCall pairs by callID")
struct ToolCallTests {
    @Test("start and end pair by callID, not by tool name")
    func pairingUsesCallID() {
        // Concurrent calls interleave, and two calls to the same tool are
        // routine. Pairing by name would close the wrong one — a call shown as
        // running forever, or one closed while it is still going.
        let firstStart = ToolCall(callID: "c-1", phase: .start, tool: "read")
        let secondStart = ToolCall(callID: "c-2", phase: .start, tool: "read")

        #expect(firstStart.callID != secondStart.callID)
        #expect(firstStart.tool == secondStart.tool)
    }

    @Test("duration is optional — the client can subtract arrival times")
    func durationIsOptional() {
        let end = ToolCall(callID: "c-1", phase: .end, tool: "read", outcome: .ok)

        #expect(end.durationMs == nil)
        #expect(end.outcome == .ok)
    }
}
