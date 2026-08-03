import Foundation
import Testing

@testable import SessionStore

/// Background resume (Amendment C §1.3): a turn carries an opaque `turnID` and
/// every stream event a monotonically increasing `seq`. On reconnect the client
/// asks the bridge for everything after `lastSeq`, so the cursor is what makes
/// "no missing text, no duplicated text" (SC-003) hold across a dropped link.
///
/// The cursor rejects replays itself rather than trusting callers: on a resume
/// boundary the bridge may re-send frames the client already stored.
@Suite("ResumeCursor — monotonic dedup boundary")
struct ResumeCursorTests {
    @Test("a fresh cursor starts before the first frame")
    func startsBeforeFirstFrame() {
        let cursor = ResumeCursor(turnID: "turn-1")

        #expect(cursor.turnID == "turn-1")
        #expect(cursor.lastSeq == ResumeCursor.beforeFirstFrame)
        #expect(cursor.resumeFrom == ResumeCursor.beforeFirstFrame)
    }

    @Test("advancing to a newer seq yields a new cursor")
    func advancesForward() throws {
        let cursor = ResumeCursor(turnID: "turn-1")

        let advanced = try #require(cursor.advanced(to: 0))

        #expect(advanced.lastSeq == 0)
        #expect(advanced.turnID == "turn-1")
        // Immutability: the original is untouched.
        #expect(cursor.lastSeq == ResumeCursor.beforeFirstFrame)
    }

    @Test("replaying an already-seen seq is dropped, not applied")
    func rejectsReplay() {
        let cursor = ResumeCursor(turnID: "turn-1", lastSeq: 7)

        #expect(cursor.advanced(to: 7) == nil)
        #expect(cursor.advanced(to: 3) == nil)
    }

    @Test("a gap is accepted — the bridge may skip seqs we never needed")
    func acceptsGap() throws {
        let cursor = ResumeCursor(turnID: "turn-1", lastSeq: 7)

        let advanced = try #require(cursor.advanced(to: 12))

        #expect(advanced.lastSeq == 12)
    }

    @Test("a frame from a different turn is never applied to this cursor")
    func rejectsForeignTurn() {
        let cursor = ResumeCursor(turnID: "turn-1", lastSeq: 7)

        #expect(cursor.accepts(turnID: "turn-1", seq: 8))
        #expect(!cursor.accepts(turnID: "turn-2", seq: 8))
    }
}
