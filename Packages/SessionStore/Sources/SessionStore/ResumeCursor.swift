import Foundation

/// Where a turn's stream got to, so it can be picked up again later.
///
/// Amendment C §1.2 makes the *connection* disposable: the host keeps
/// generating and buffering while the app is backgrounded or killed, and the
/// client asks for everything after `lastSeq` when it returns. That only works
/// if the cursor outlives the process, which is why it is persisted here rather
/// than held in a running actor.
///
/// The cursor also owns dedup. On a resume boundary the bridge may replay
/// frames the client already stored, and `advanced(to:)` refuses to move
/// backwards — this is the mechanism behind "no missing text, no duplicated
/// text" (SC-003) when the link drops mid-answer.
public struct ResumeCursor: Hashable, Sendable, Codable {
    /// Sentinel for "nothing received yet". Sequence numbers start at 0, so the
    /// resume point before the first frame has to sit below it.
    public static let beforeFirstFrame = -1

    /// Opaque turn identifier issued by the bridge. Unpredictable by contract
    /// (Amendment C §5), so it is never derived or guessed locally.
    public let turnID: String
    /// Highest sequence number durably stored for this turn.
    public let lastSeq: Int

    public init(turnID: String, lastSeq: Int = ResumeCursor.beforeFirstFrame) {
        self.turnID = turnID
        self.lastSeq = lastSeq
    }

    /// The value to send as `x-localis-resume-from`.
    public var resumeFrom: Int { lastSeq }

    /// Whether a freshly arrived frame belongs to this turn and is new.
    ///
    /// A frame from another turn is never this cursor's business — mixing them
    /// would let one turn's progress mark another's.
    public func accepts(turnID incomingTurnID: String, seq: Int) -> Bool {
        incomingTurnID == turnID && seq > lastSeq
    }

    /// Returns a cursor advanced to `seq`, or `nil` if the frame is a replay.
    ///
    /// A *gap* (seq jumps past values never seen) is accepted: the bridge
    /// decides what to replay, and refusing a gap would strand the turn forever.
    public func advanced(to seq: Int) -> ResumeCursor? {
        guard seq > lastSeq else { return nil }
        return ResumeCursor(turnID: turnID, lastSeq: seq)
    }
}
