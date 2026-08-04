import Foundation

/// Whether a failed turn is safe to retry without `--resume`.
///
/// **This type exists to say "no" most of the time.** A turn that failed after
/// the CLI started working may have already run a command on the user's
/// machine; retrying it would run that command twice. So the question is not
/// "did it fail?" but "can I prove it never started?" — and anything short of
/// proof is answered `false`.
///
/// The one provable case is a `--resume` naming a conversation the CLI does not
/// have. Observed 2026-08-04 against the real CLI:
///
/// ```
/// $ claude -p "…" --resume 00000000-dead-4000-8000-000000000000
/// exit 1
/// stderr: No conversation found with session ID: 00000000-dead-4000-8000-000000000000
/// stdout: {"type":"result","is_error":true,"num_turns":0,
///          "session_id":"00000000-dead-4000-8000-000000000000",
///          "errors":["No conversation found with session ID: …"]}
/// ```
///
/// The CLI rejects the invocation before any turn runs. `num_turns` is `0`
/// because nothing ran — not because the run produced nothing.
public enum ResumeFailure {
    /// The sentence the CLI prints when `--resume` names nothing it has.
    ///
    /// Matched as a prefix of an entry in the frame's own `errors` array, not
    /// against stderr. Two reasons: stderr is drained and discarded on purpose
    /// (it names absolute paths — constitution §I), and a structured field is a
    /// narrower thing to match than a text stream that carries progress output
    /// as well.
    private static let notFoundPrefix = "No conversation found with session ID"

    /// Whether this result frame proves the turn never started *and* names a
    /// missing conversation as the reason.
    ///
    /// **Both conditions, never either.** `num_turns == 0` alone is not enough:
    /// a turn can fail at zero turns for reasons that did reach the machine
    /// (a backend outage mid-handshake, a killed process). The message alone is
    /// not enough either, because a future CLI could report it after doing
    /// work. Requiring both means a new failure mode defaults to *not*
    /// retrying, which is the direction that cannot execute a user's message
    /// twice.
    public static func isRetryableWithoutResume(frame: [String: Any]) -> Bool {
        guard frame["is_error"] as? Bool == true else { return false }

        // Absent is not zero. A frame with no `num_turns` has not told us the
        // turn ran zero times — it has told us nothing, and nothing is not
        // proof.
        guard let turns = frame["num_turns"] as? Int, turns == 0 else { return false }

        guard let errors = frame["errors"] as? [String] else { return false }
        return errors.contains { $0.hasPrefix(notFoundPrefix) }
    }
}
