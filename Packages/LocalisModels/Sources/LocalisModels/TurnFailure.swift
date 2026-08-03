import Foundation

/// Why and how far along a turn failed (Amendment C, contract §3.1(d)).
///
/// The bridge sends `failed_at_ms` and `tool_calls_completed` on
/// `x-localis-turn-end` with `outcome: failed`, and the contract makes both
/// **required** there: a failure has to be *actionable*, which means the user
/// learns "failed 8 minutes in, after 3 tool calls" rather than a bare "Error".
///
/// It is modelled here, on the message, rather than only on the stream event,
/// because of the exact case background resume exists for: the user may
/// force-quit before ever seeing the failure. A detail that lives only in a
/// transient event is gone by the time they look, and what comes back is the
/// bare "Error" the contract set out to prevent.
///
/// Note what is *not* here: the bridge's `error.message`. Its wording is carried
/// by `LocalisError`, derived locally from the code, because the bridge's own
/// text may contain absolute paths (constitution I).
public struct TurnFailure: Hashable, Codable, Sendable {
    /// Elapsed milliseconds from the start of the turn to the failure.
    public let failedAtMs: Int
    /// Tool calls that finished before the turn died.
    ///
    /// Zero is a real answer — a turn can fail before any tool runs — not a
    /// stand-in for "unknown".
    public let toolCallsCompleted: Int

    /// Negative inputs are clamped to zero rather than rejected.
    ///
    /// Neither value can be negative in a real turn, so a negative one means a
    /// malformed frame. Refusing the whole record over it would trade a slightly
    /// wrong number for no failure detail at all — the very outcome this type
    /// exists to prevent. Clamping keeps the record and discards only nonsense.
    public init(failedAtMs: Int, toolCallsCompleted: Int) {
        self.failedAtMs = max(0, failedAtMs)
        self.toolCallsCompleted = max(0, toolCallsCompleted)
    }

    /// Elapsed time as seconds, for formatting at the UI boundary.
    public var elapsed: TimeInterval { TimeInterval(failedAtMs) / 1000 }
}
