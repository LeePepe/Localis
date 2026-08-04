import Foundation
import Testing
import LocalisModels
@testable import TransportKit

/// A transport failure must name *which half of the system* failed.
///
/// **Why this suite exists.** Both request paths used to end in one catch-all
/// that answered `.unreachable` for every error the network layer could
/// produce. `.unreachable` renders as "the Mac is asleep or off the network",
/// so a rejected certificate sent the user to check their router and their
/// power cable while the actual cause was that the host was presenting a
/// different key than the one they pinned.
///
/// That is not merely unhelpful wording. `certificatePinMismatch` is the one
/// error constitution V forbids overriding, and folding it into "offline"
/// makes the single failure pinning exists to announce indistinguishable from
/// a sleeping laptop (#34).
///
/// The split asserted here is deliberately **not** "recognised versus
/// unrecognised". Anything this code cannot place stays `.unreachable`:
/// guessing a specific cause is how the wrong half gets named, which is the
/// defect this suite guards against in the first place.
@Suite("Transport failures name the half that failed")
struct TransportFailureMappingTests {
    // MARK: - TLS

    /// The system's own default trust evaluation rejected the chain.
    ///
    /// Reached whenever the pinning delegate does not run — the self-signed
    /// certificate a paired bridge presents cannot satisfy the system policy,
    /// so this is what a mis-wired pin looks like from the caller.
    @Test("a certificate the system rejects is a pin mismatch, not an outage")
    func serverCertificateUntrustedIsPinMismatch() {
        #expect(
            TransportFailure.classify(URLError(.serverCertificateUntrusted)) == .certificatePinMismatch
        )
    }

    @Test("every server-certificate rejection names the certificate")
    func allCertificateErrorsArePinMismatch() {
        let certificateFailures: [URLError.Code] = [
            .serverCertificateUntrusted,
            .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired,
            .secureConnectionFailed,
        ]

        for code in certificateFailures {
            #expect(
                TransportFailure.classify(URLError(code)) == .certificatePinMismatch,
                "URLError code \(code.rawValue) fell through to a generic failure, so the user is told the host is offline when its certificate is the problem"
            )
        }
    }

    // MARK: - Network

    /// The cases that really are "the Mac is not answering".
    ///
    /// Asserted as a group because the previous behaviour answered
    /// `.unreachable` for *everything*: a test that only checked the
    /// certificate half would pass just as well against a mapping that had
    /// quietly turned every network error into a pin mismatch — the same
    /// mistake in the other direction, and a far more alarming one to show a
    /// user.
    @Test("the errors that really are an outage stay unreachable")
    func networkFailuresStayUnreachable() {
        let outages: [URLError.Code] = [
            .cannotConnectToHost,
            .cannotFindHost,
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed,
        ]

        for code in outages {
            // Matches the case, not the whole value. Since #34 the fallback
            // carries the OS's domain and code, so `== .unreachable()` would
            // assert the diagnostic is *absent* — the opposite of what this
            // path does — and every one of these would fail for a reason
            // unrelated to what the test is named for.
            guard case .unreachable(let diagnostic) = TransportFailure.classify(URLError(code)) else {
                Issue.record("URLError code \(code.rawValue) was reported as a certificate problem, which tells the user their host may be impersonated when it is simply not answering")
                continue
            }
            // The category is coarse on purpose; the code is what makes a
            // timeout distinguishable from a DNS failure in a log (#34).
            #expect(
                diagnostic?.code == code.rawValue,
                "URLError code \(code.rawValue) reached the user coarsely and left no way to tell which outage it was"
            )
        }
    }

    // MARK: - Everything else

    /// An error this code has no opinion about must not acquire one.
    @Test("an unrecognised URL error stays unreachable rather than being guessed")
    func unrecognisedURLErrorStaysUnreachable() {
        guard case .unreachable(let diagnostic) = TransportFailure.classify(URLError(.unsupportedURL)) else {
            Issue.record("an unrecognised URL error acquired a specific cause")
            return
        }
        // Vaguest answer, so the one most worth being able to look up (#34).
        #expect(diagnostic?.code == URLError.Code.unsupportedURL.rawValue)
    }

    /// Not every failure that reaches the catch-all is a `URLError`.
    @Test("a non-URL error stays unreachable")
    func foreignErrorStaysUnreachable() {
        struct Unexpected: Error {}
        guard case .unreachable(let diagnostic) = TransportFailure.classify(Unexpected()) else {
            Issue.record("a foreign error acquired a specific cause")
            return
        }
        // Restricting the diagnostic to `URLError` would be the same catch-all
        // one layer down, invisible because nobody writes a test for the errors
        // they did not think of. The `NSError` identity exists for every error.
        #expect(diagnostic != nil, "a foreign error left no identity behind at all")
    }

    /// A `LocalisError` that already crossed a boundary keeps its identity.
    ///
    /// Both call sites re-throw these before reaching `classify`, but the
    /// function is the thing another call site will reuse, and re-deriving a
    /// cause from an error that already has one is how a precise failure
    /// becomes a vague one.
    @Test("an error that is already ours is not re-derived")
    func localisErrorPassesThrough() {
        #expect(TransportFailure.classify(LocalisError.tokenRevoked) == .tokenRevoked)
        #expect(TransportFailure.classify(LocalisError.sessionBusy) == .sessionBusy)
    }

    // MARK: - Cancellation

    /// A cancelled request is not an outage.
    ///
    /// `-999` is what `URLSession` reports when *anything* cancels a task,
    /// including our own pinning delegate refusing a challenge. Naming it
    /// `.cancelled` rather than `.unreachable` is true in both readings; the
    /// question of whether a delegate refusal can be told apart from a user
    /// cancellation is #34's open half and is deliberately not decided here.
    @Test("a cancelled request is cancelled, not an outage")
    func cancellationIsNotAnOutage() {
        #expect(TransportFailure.classify(URLError(.cancelled)) == .cancelled)
    }
}
