import Foundation

/// The resume cursor for one in-flight assistant turn (Amendment C §1.2,
/// contract §3.3).
///
/// This type is what makes "the user backgrounded the app" and "the user killed
/// the app" the same event. The generation's authority lives on the host, so the
/// connection is disposable — but only if the client can say exactly how far it
/// got. That is `lastSeq`.
///
/// Both halves matter and neither is optional in the protocol sense:
/// - `turnID` addresses the turn on the host (`POST /v1/turns/{turn_id}/resume`).
/// - `lastSeq` becomes `x-localis-resume-from`, and doubles as the dedup rule at
///   the replay boundary — SC-003's "no missing text, no duplicated text" is
///   this one comparison.
///
/// Persisting it is not optional: a cursor that only lives in memory cannot
/// survive the app being killed, which is precisely the case it exists for.
public struct TurnCursor: Hashable, Codable, Sendable {
    /// The host's opaque turn identifier.
    ///
    /// A plain `String` on purpose. The contract requires it to be
    /// unpredictable, and the client neither generates nor parses it — wrapping
    /// it in a structured type would imply we understand its insides and invite
    /// someone to read meaning out of it.
    public let turnID: String

    /// The highest `seq` accepted so far, or `nil` before the first event.
    ///
    /// `seq` counts from 0 per turn, so "nothing accepted yet" cannot be spelled
    /// as `0` or `-1` — the first would silently skip event 0, the second would
    /// be a sentinel pretending to be a sequence number.
    public let lastSeq: Int?

    public init(turnID: String, lastSeq: Int? = nil) {
        self.turnID = turnID
        self.lastSeq = lastSeq
    }

    /// The value for the `x-localis-resume-from` header.
    ///
    /// Deliberately the *last accepted* seq, not the next wanted one: the bridge
    /// replays from `seq + 1`. Sending the next wanted value would skip exactly
    /// one frame — an off-by-one that shows up as a missing word mid-sentence.
    public var resumeFrom: Int? { lastSeq }

    /// Whether an arriving event is new.
    ///
    /// At the replay boundary the bridge may resend frames the client already
    /// has. Accepting one twice is how a transcript grows duplicated text.
    ///
    /// A *gap* is accepted on purpose: the bridge decides what to replay, and a
    /// client that demanded consecutive `seq` would strand a turn forever the
    /// moment the bridge skipped one.
    public func shouldAccept(seq: Int) -> Bool {
        guard let lastSeq else { return true }
        return seq > lastSeq
    }

    /// Whether an arriving event belongs to this turn *and* is new.
    ///
    /// The turn check is not redundant with `shouldAccept`. `seq` counts per
    /// turn, so another turn's frame carries numbers in exactly the same range —
    /// comparing sequence alone would let one turn's progress mark another's.
    /// Prefer this over `shouldAccept` wherever the turn id is at hand.
    public func accepts(turnID incomingTurnID: String, seq: Int) -> Bool {
        incomingTurnID == turnID && shouldAccept(seq: seq)
    }

    /// Advances the cursor, ignoring anything that would move it backwards.
    ///
    /// After a resume the old connection may still deliver a late frame. Letting
    /// it rewind the cursor would re-open the window it was closing.
    public func advanced(to seq: Int) -> TurnCursor {
        guard shouldAccept(seq: seq) else { return self }
        return TurnCursor(turnID: turnID, lastSeq: seq)
    }
}
