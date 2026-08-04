import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// A socket failure must name what went wrong, not only that something did (#34).
///
/// `perform`'s catch-all collapses every non-`LocalisError` into `.unreachable`.
/// That is right about *category* and destroys the only part worth acting on:
/// `NSURLErrorDomain -1202` (certificate rejected) and a genuinely dead route
/// need opposite fixes — one is local trust configuration, the other is the
/// network or the address — and after the collapse they are the same value to
/// every caller. #32 was diagnosed from the wrong end for several rounds
/// because of exactly this.
///
/// **What may be carried, and what may not.** `domain` is a constant name
/// (`NSURLErrorDomain`) and `code` is a number, both produced by Foundation on
/// this device. Neither comes from the bridge. The bridge's own `error.message`
/// stays out (constitution I / FR-025) because it may hold an absolute path,
/// and so do the token, the host name, and any certificate bytes.
@Suite("a transport failure keeps its cause")
struct TransportDiagnosticTests {
    // MARK: - The cause survives

    /// The case #32 was misdiagnosed from. A pin mismatch reaching a caller as
    /// a bare "unreachable" sends whoever reads it to check the network, which
    /// is the one thing that is fine.
    @Test("a rejected certificate is distinguishable from a dead route")
    func certificateFailureIsNotBareUnreachable() async throws {
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        let http = StubStreamingHTTP(responses: [.failure(refused)])

        do {
            _ = try await Self.client(http).models()
            Issue.record("expected the socket failure to surface")
        } catch let error as LocalisError {
            let diagnostic = try #require(
                error.diagnostic,
                "the underlying NSError's identity was discarded — the collapse #34 is about"
            )
            #expect(diagnostic.domain == NSURLErrorDomain)
            #expect(diagnostic.code == NSURLErrorSecureConnectionFailed)
        }
    }

    /// Two different socket failures must not read as the same error. Asserting
    /// one code in isolation would pass against an implementation that
    /// hardcoded it, which is the failure mode a single positive case cannot
    /// see.
    @Test("two different socket failures do not collapse into each other")
    func distinctFailuresStayDistinct() async throws {
        let first = try await Self.diagnostic(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        )
        let second = try await Self.diagnostic(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        )

        #expect(first != second)
        #expect(first.code == NSURLErrorCannotFindHost)
        #expect(second.code == NSURLErrorSecureConnectionFailed)
    }

    /// A non-`URLError` domain must survive too. Restricting the diagnostic to
    /// `URLError` would put a second catch-all one layer down: everything else
    /// would arrive with no cause, and the gap would be invisible because the
    /// URL cases — the ones anyone writes tests for — all work.
    @Test("a failure from another domain keeps its own domain")
    func foreignDomainSurvives() async throws {
        let diagnostic = try await Self.diagnostic(
            from: NSError(domain: NSPOSIXErrorDomain, code: 61)
        )

        #expect(diagnostic.domain == NSPOSIXErrorDomain)
        #expect(diagnostic.code == 61)
    }

    // MARK: - What must not be carried

    /// Constitution I / FR-025. `NSError.userInfo` routinely holds
    /// `NSLocalizedDescription` and `NSURLErrorFailingURLStringErrorKey`, and
    /// the failing URL contains the host — which is the user's machine name.
    ///
    /// Written against `String(describing:)` rather than against named fields:
    /// a field added later that happens to hold the path would pass a
    /// field-by-field check and fail this one.
    @Test("nothing but domain and code rides out")
    func diagnosticCarriesNothingElse() async throws {
        let leaky = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorSecureConnectionFailed,
            userInfo: [
                NSLocalizedDescriptionKey: "/Users/someone/Library/secret.pem is not trusted",
                NSURLErrorFailingURLStringErrorKey: "https://someones-macbook.local:8443/v1/models",
            ]
        )
        let http = StubStreamingHTTP(responses: [.failure(leaky)])

        do {
            _ = try await Self.client(http).models()
            Issue.record("expected the socket failure to surface")
        } catch {
            let described = String(describing: error)
            #expect(described.contains("/Users") == false)
            #expect(described.contains("secret") == false)
            #expect(described.contains("someones-macbook") == false)
            #expect(described.contains("8443") == false)
            #expect(described.contains("not trusted") == false)
        }
    }

    /// The diagnostic is for a log, not a screen. If `userMessage` ever read
    /// it, constitution I's boundary would quietly become "we carry it but hope
    /// nobody renders it" — and the four sentences a user can act on would grow
    /// a numeric tail that means nothing to them.
    @Test("the diagnostic never reaches the user-facing wording")
    func diagnosticIsNotUserFacing() async throws {
        let diagnosed = try await Self.error(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        )

        #expect(diagnosed.userMessage == LocalisError.unreachable().userMessage)
        #expect(diagnosed.userMessage.contains("\(NSURLErrorSecureConnectionFailed)") == false)
        #expect(diagnosed.userMessage.contains("NSURLError") == false)
    }

    // MARK: - The category is unchanged

    /// #34 adds a cause; it does not reclassify. A socket failure is still
    /// `unreachable`, still retryable, and still reads as `.offline` to the
    /// host list (#40) — a diagnostic that also moved failures between
    /// categories would break callers that are correct today.
    @Test("carrying a cause does not change what the failure is")
    func categoryUnchanged() async throws {
        let diagnosed = try await Self.error(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        )

        #expect(diagnosed.isRetryable == LocalisError.unreachable().isRetryable)
        #expect(HostReachability(failure: diagnosed) == .unreachable(reason: .offline))
    }

    // MARK: - Helpers

    /// The port is deliberately not 8443. `diagnosticCarriesNothingElse`
    /// asserts that `8443` — the port in the planted `userInfo` URL — does not
    /// ride out; if the client under test also used 8443, that assertion would
    /// be reading a number that could have come from either place.
    private static func client(_ http: StubStreamingHTTP) -> BridgeClient {
        BridgeClient(
            host: HostID(),
            endpoint: HostEndpoint(host: "mac.local", port: 9443),
            token: "opaque-token",
            http: http
        )
    }

    /// Runs one request that fails at the socket and returns the `LocalisError`.
    private static func error(from underlying: NSError) async throws -> LocalisError {
        let http = StubStreamingHTTP(responses: [.failure(underlying)])
        do {
            _ = try await client(http).models()
            Issue.record("expected the socket failure to surface")
            return .unreachable()
        } catch let error as LocalisError {
            return error
        }
    }

    private static func diagnostic(from underlying: NSError) async throws -> TransportDiagnostic {
        try #require(await error(from: underlying).diagnostic)
    }
}
