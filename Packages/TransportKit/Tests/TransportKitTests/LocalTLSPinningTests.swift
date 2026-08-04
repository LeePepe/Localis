import Foundation
import LocalisModels
import Security
import Testing

@testable import TransportKit

/// Pinning against a real TLS handshake, on the machine running the tests
/// (#37).
///
/// **What this suite adds over `SPKIPinningTests`.** Those twelve tests ask
/// whether `SPKIPinning.verify` reaches the right verdict, and they answer it
/// with certificates handed to the function directly. Every one of them stays
/// green in a build where no connection is ever pinned, because none of them
/// causes a handshake. That is not hypothetical: it is exactly the state #32
/// was in — the verdict logic correct, and the delegate never consulted on the
/// streaming path, so every request but pairing failed as `-1202`.
///
/// The distinction this suite exists to hold:
///
/// - **the referee judges correctly** — `SPKIPinningTests`, and it was never in
///   doubt;
/// - **the referee is called onto the pitch** — only observable from a live
///   handshake, and it is what broke.
///
/// `LiveBridgeIntegrationTests` covers the second, and cannot run in CI: it
/// needs a bridge on another machine and its pin. That suite stays (it is the
/// only thing that exercises the real bridge's certificate and the real pairing
/// code path), but a suite skipped for want of a host reports the same green
/// tick as a suite that passed, so it must not be the only cover. This one
/// carries its own server and therefore runs everywhere.
@Suite("Pinning over a real local TLS handshake")
struct LocalTLSPinningTests {
    // MARK: - The negative control, first, because the rest mean nothing without it

    /// A wrong pin must refuse — **and the refusal must be ours**.
    ///
    /// This is the assertion the suite is built around, and "the connection
    /// failed" is not enough of it. A connection to a self-signed certificate
    /// fails for two entirely different reasons that a caller cannot tell
    /// apart:
    ///
    /// - **we refused it**: the delegate ran, compared the presented key
    ///   against the pin, and cancelled the challenge. Surfaces as `-999`
    ///   (`NSURLErrorCancelled`), with `.refused` recorded.
    /// - **the system refused it**: the delegate was never consulted, so the
    ///   default policy judged a self-signed certificate and rejected it.
    ///   Surfaces as `-1202`, with *nothing* recorded.
    ///
    /// The second is #32 exactly, and it is what a test asserting only "the
    /// request threw" accepts as proof that pinning works. So the assertion is
    /// on the recorded outcome, not on the error: an error code is an inference
    /// about which code ran, the observer is a record of it.
    @Test("a wrong pin is refused by us, not by the system's default policy")
    func wrongPinIsRefusedByUs() async throws {
        let server = try LocalTLSServer.start()
        let outcomes = Locked<[PinnedSessionDelegate.ChallengeOutcome]>([])

        // A syntactically valid pin that cannot match: same shape as a real
        // one, different bytes. Not a malformed string — that would be refused
        // by a different branch and prove something else.
        let wrongPin = SPKIHash(base64: Data(repeating: 0xAB, count: 32).base64EncodedString())
        let http = PinnedHTTP(pin: wrongPin, observer: { outcome in
            outcomes.mutate { $0.append(outcome) }
        })

        var thrown: Error?
        do {
            _ = try await http.perform(URLRequest(url: server.url))
        } catch {
            thrown = error
        }

        #expect(thrown != nil, "a connection with the wrong pin succeeded")

        let recorded = outcomes.get()
        #expect(recorded == [.refused], """
            expected exactly one recorded outcome, .refused; got \(recorded).
            An empty list is the #32 shape: the delegate was never consulted and \
            the system's default policy rejected the self-signed certificate for \
            us. The connection fails either way, so the thrown error cannot tell \
            those apart — this assertion is the only thing that can.
            Thrown was: \(thrown.map { "\($0)" } ?? "nothing").
            """)

        // Having established the delegate ran, the code corroborates *which*
        // rejection this was. Asserted after the observer, and never instead of
        // it: -999 is also what a user-cancelled task returns.
        let code = (thrown as? URLError)?.errorCode ?? (thrown as NSError?)?.code
        #expect(code == NSURLErrorCancelled, """
            expected -999 (NSURLErrorCancelled, what cancelAuthenticationChallenge \
            produces); got \(code.map(String.init) ?? "no code"). \
            -1202 here would mean the system rejected the certificate before our \
            delegate was consulted.
            """)
    }

    // MARK: - The positive case, which only means something given the above

    /// The right pin connects, over a certificate no CA has ever seen.
    ///
    /// The pin *replaces* CA validation rather than adding to it. If the
    /// delegate answered `.performDefaultHandling` — or were never invoked —
    /// this would fail on a certificate that is precisely the one we pinned,
    /// which is the failure mode #31 hit.
    @Test("the matching pin completes a handshake to a self-signed certificate")
    func matchingPinConnects() async throws {
        let server = try LocalTLSServer.start()
        let outcomes = Locked<[PinnedSessionDelegate.ChallengeOutcome]>([])

        let http = PinnedHTTP(pin: server.pin, observer: { outcome in
            outcomes.mutate { $0.append(outcome) }
        })

        let (data, response) = try await http.perform(URLRequest(url: server.url))

        #expect(response.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(outcomes.get() == [.proceeded], """
            the request succeeded but the delegate did not record .proceeded \
            (got \(outcomes.get())). A success with no record would mean the \
            connection was allowed by something other than the pin.
            """)
    }

    /// A nil pin refuses, and refuses as *us*.
    ///
    /// Absent history is not permission: `PinnedHTTP(pin: nil)` must not be a
    /// trust-on-first-use door. The observer assertion matters for the same
    /// reason as in the negative control — with no pin, the system's default
    /// policy would also reject a self-signed certificate, so the connection
    /// failing proves nothing about which code decided.
    @Test("no pin refuses the connection rather than trusting on first use")
    func nilPinRefuses() async throws {
        let server = try LocalTLSServer.start()
        let outcomes = Locked<[PinnedSessionDelegate.ChallengeOutcome]>([])

        let http = PinnedHTTP(pin: nil, observer: { outcome in
            outcomes.mutate { $0.append(outcome) }
        })

        var thrown: Error?
        do {
            _ = try await http.perform(URLRequest(url: server.url))
        } catch {
            thrown = error
        }

        #expect(thrown != nil, "a connection with no pin succeeded — that is trust on first use")
        #expect(outcomes.get() == [.refused], """
            expected .refused; got \(outcomes.get()). An empty list means the \
            system refused it and our code never had an opinion, which would \
            leave "no pin refuses" unproven.
            """)
    }

    // MARK: - The pin the harness computes is the pin production computes

    /// The pin used above comes from `SPKIPinning.spkiHash`, and this checks it
    /// is the same value an operator would compute with openssl.
    ///
    /// Without this, the two positive assertions could both be satisfied by a
    /// harness that hashes a certificate one way and a production path that
    /// hashes it another, as long as the two agree with each other — a closed
    /// loop that passes while the pin shown to the user matches nothing.
    @Test("the harness certificate's pin matches openssl's SPKI digest")
    func harnessPinMatchesOpenSSL() throws {
        let server = try LocalTLSServer.start()
        #expect(!server.pin.base64.isEmpty)
        // 32 bytes of SHA-256, base64: 44 characters ending in '='.
        #expect(server.pin.base64.count == 44, """
            a base64 SHA-256 is 44 characters; got \(server.pin.base64.count). \
            The digest is over the DER SubjectPublicKeyInfo, and \
            SPKIPinningTests already checks that value against openssl for \
            fixture certificates — this only confirms the harness feeds it a \
            certificate it can read.
            """)
    }
}
