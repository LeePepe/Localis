import Foundation
import Testing

@testable import LocalisModels

/// Amendment C §1.2 / contract §3.3.
///
/// The cursor is what makes "killed the app" and "backgrounded the app" the same
/// event. Every property here is really a claim about SC-003 — no missing text,
/// no duplicated text — held up across a dropped connection.
@Suite("TurnCursor")
struct TurnCursorTests {
    @Test("a fresh cursor accepts the first event")
    func freshCursorAcceptsFirstEvent() {
        // seq counts from 0 per turn, so the cursor must start below it.
        let cursor = TurnCursor(turnID: "t-9")

        #expect(cursor.shouldAccept(seq: 0))
        #expect(cursor.lastSeq == nil)
    }

    @Test("an event already seen is dropped")
    func replayedEventIsDropped() {
        // The resume boundary re-sends frames the client already has. Accepting
        // them a second time is how a transcript grows duplicated text.
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 42)

        #expect(!cursor.shouldAccept(seq: 42))
        #expect(!cursor.shouldAccept(seq: 7))
        #expect(cursor.shouldAccept(seq: 43))
    }

    @Test("advancing moves the cursor forward")
    func advancingMovesForward() {
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 42)

        let next = cursor.advanced(to: 43)

        #expect(next.lastSeq == 43)
        #expect(next.turnID == "t-9")
        #expect(cursor.lastSeq == 42)
    }

    @Test("the cursor never moves backwards")
    func cursorNeverRegresses() {
        // A late frame from the old connection arriving after a resume must not
        // rewind the cursor — that would re-open the window for duplicates.
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 42)

        #expect(cursor.advanced(to: 7).lastSeq == 42)
        #expect(cursor.advanced(to: 42).lastSeq == 42)
    }

    @Test("the resume point is one past the last accepted event")
    func resumeFromIsLastAccepted() {
        // The header is `x-localis-resume-from: <last accepted seq>` and the
        // bridge replays from seq+1. Sending the *next* wanted seq instead would
        // silently skip exactly one frame.
        #expect(TurnCursor(turnID: "t-9", lastSeq: 42).resumeFrom == 42)
        #expect(TurnCursor(turnID: "t-9").resumeFrom == nil)
    }

    @Test("the turn id is carried opaquely")
    func turnIDIsOpaque() {
        // Contract §3.3: `turn_id` MUST be unpredictable. The client neither
        // generates nor parses it — a structured type here would imply we
        // understand its insides.
        let cursor = TurnCursor(turnID: "01J8Z3-not-a-counter")

        #expect(cursor.turnID == "01J8Z3-not-a-counter")
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 42)

        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(TurnCursor.self, from: data)

        #expect(decoded == cursor)
    }

    @Test("cursors for different turns are different cursors")
    func turnIDParticipatesInEquality() {
        // Resumed content is filed by (hostID, sessionID, turnID) — contract
        // §3.3. Two turns at the same seq are not interchangeable.
        #expect(TurnCursor(turnID: "t-1", lastSeq: 5) != TurnCursor(turnID: "t-2", lastSeq: 5))
    }
}
