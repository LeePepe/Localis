import Foundation
import Testing

@testable import LocalisModels

/// One mapping from the bridge's `error.code` to the app's error vocabulary,
/// shared by every layer that reads one off the wire (contract §6).
///
/// It lives here rather than in each layer for the reason the vocabulary itself
/// does: three copies are three implementations that can each be wrong
/// differently, and the one that drifts is invisible until a user hits exactly
/// that code on exactly that path.
@Suite("LocalisError maps the contract's wire codes")
struct LocalisErrorWireTests {
    @Test("every code in the contract's table has a mapping")
    func contractCodesMap() {
        #expect(LocalisError(wireCode: "invalid_token") == .unauthorized)
        #expect(LocalisError(wireCode: "token_revoked") == .tokenRevoked)
        #expect(LocalisError(wireCode: "unknown_model") == .unknownBackend)
        #expect(LocalisError(wireCode: "session_busy") == .sessionBusy)
        #expect(LocalisError(wireCode: "unknown_turn") == .unknownTurn)
        #expect(LocalisError(wireCode: "turn_expired") == .turnExpired)
        #expect(LocalisError(wireCode: "turn_not_yours") == .turnNotYours)
    }

    @Test("backend_unavailable keeps no reason when the wire sent none")
    func backendUnavailableWithoutReason() {
        // The reason is a machine code the host may omit. Inventing one would
        // put words in the host's mouth about why its backend is down.
        #expect(LocalisError(wireCode: "backend_unavailable") == .backendUnavailable(reason: nil))
    }

    @Test("an unrecognised code is not silently downgraded to a success")
    func unknownCodeIsAnError() {
        // The failure mode worth naming: returning `nil` for an unknown code
        // invites the caller to write `?? nothing-happened`, which reports a
        // failed turn as fine. A code we cannot name is still a failure.
        let mapped = LocalisError(wireCode: "quota_exhausted")

        #expect(mapped == .malformedResponse)
    }

    @Test("an unrecognised code stays retryable")
    func unknownCodeIsRetryable() {
        // "We don't know what went wrong" and "we know it cannot be fixed by
        // retrying" are different claims. Defaulting to the second takes the
        // retry away from a user whose next attempt might well have worked.
        #expect(LocalisError(wireCode: "quota_exhausted").isRetryable)
    }

    @Test("an absent code is a failure with no detail, not a non-failure")
    func absentCodeIsStillAFailure() {
        // A bridge reporting `outcome: failed` with no code has still failed.
        #expect(LocalisError(wireCode: nil) == .malformedResponse)
    }

    @Test("the mapping never carries the bridge's own wording")
    func wireTextIsNeverTheMessage() {
        // Constitution I / FR-025: `error.message` may contain absolute paths.
        // A caller passing the *message* where a code belongs must not end up
        // showing it to the user.
        let leaky = LocalisError(wireCode: "/Users/someone/secret/path failed")

        #expect(!leaky.userMessage.contains("/Users/"))
    }
}
