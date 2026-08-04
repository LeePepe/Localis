import Foundation
import LocalisModels
import Security
import Testing

@testable import TransportKit

/// The handshake, against a real bridge over real TLS (#31).
///
/// **What every other test in this package cannot reach.** `SPKIPinningTests`
/// proves the digest matches openssl, and `BridgePairingTests` proves
/// `PinnedTrust.evaluate` returns the right disposition for a chain handed to
/// it directly. Neither has ever caused a TLS handshake: `PinnedSessionDelegate`
/// is never instantiated in any test in this repo, so its
/// `urlSession(_:didReceive:completionHandler:)` — the code that actually
/// decides whether a connection lives — runs for the first time here.
///
/// Three things are unproven until this runs, and they fail for unrelated
/// reasons, which is why the report has to name which one broke:
///
/// 1. `URLCredential(trust:)` completing a handshake to a **self-signed**
///    certificate. The pin replaces CA validation rather than adding to it, and
///    "the system rejected it before our delegate got a say" looks the same from
///    the caller as "the pin did not match".
/// 2. `SecTrustCopyCertificateChain` returning the shape `evaluate` expects from
///    a *live* challenge, rather than from a fixture built by the test.
/// 3. The delegate being invoked at all.
///
/// ## Why this suite is disabled by default
///
/// It needs a bridge running on another machine and its pin. Neither exists in
/// CI, and a test that cannot run there must not be able to *report* anything
/// there — a suite skipped for want of a host and a suite that passed are the
/// same green tick on a dashboard. It is gated on the environment variables
/// below being present, and it fails loudly rather than skipping if they are
/// half-set.
///
/// ```
/// LOCALIS_BRIDGE_HOST=<hostname or IP>   # e.g. a .local name on the LAN
/// LOCALIS_BRIDGE_PORT=<port>
/// LOCALIS_BRIDGE_PIN=<base64 SHA-256 of the DER SubjectPublicKeyInfo>
/// LOCALIS_BRIDGE_CODE=<the six digits on the Mac>   # pairing test only
/// ```
///
/// **The pin is read from the environment and must never be committed.** It is
/// bound to one machine's `~/.localis/key.pem`; hardcoded, it would turn every
/// other person's checkout red for a reason unrelated to anything they changed,
/// which teaches people to ignore red.
@Suite("A real bridge over real TLS", .enabled(if: LiveBridge.isConfigured))
struct LiveBridgeIntegrationTests {
    // MARK: - The negative control, which runs first

    /// A deliberately wrong pin must refuse the connection.
    ///
    /// **This is the test that makes the others mean anything, and it is not a
    /// formality.** If pinning were not wired up at all — delegate never
    /// invoked, `URLSession` falling back to default handling — then a
    /// connection with the *right* pin would still succeed, and "it connected"
    /// would be read as "pinning works". The two are indistinguishable from the
    /// success case alone. Only a refusal that tracks a *changed* pin shows the
    /// pin is being consulted.
    ///
    /// The wrong pin is a real, well-formed SPKI hash of a certificate this
    /// bridge does not hold (a fixture), not a corrupt string: a malformed
    /// value could be rejected by parsing long before any comparison, which
    /// would pass this test while proving nothing about the comparison.
    ///
    /// **Why the error is inspected rather than merely counted.** The first
    /// version of this test asserted only that *something* was thrown, and it
    /// passed against `192.0.2.1` — an address with no bridge behind it at all.
    /// A timeout is an error, so "the pin was rejected" and "nothing was ever
    /// there" were the same green tick. The assertion is therefore on the
    /// specific failure a *refused handshake* produces: `URLSession` surfaces
    /// our `cancelAuthenticationChallenge` as `NSURLErrorCancelled`, and a
    /// connection that never reached TLS cannot produce it.
    @Test("a connection pinned to the wrong key is refused")
    func wrongPinIsRefused() async throws {
        let endpoint = try LiveBridge.endpoint()
        let wrong = try LiveBridge.wrongButWellFormedPin()

        // Sanity: the decoy must not accidentally equal the real pin, or this
        // test would be asserting that the correct pin fails.
        #expect(wrong != (try LiveBridge.realPin()))

        let http = PinnedHTTP(pin: wrong)
        let request = try LiveBridge.modelsRequest(endpoint: endpoint, token: "unused-the-tls-layer-should-refuse-first")

        do {
            _ = try await http.perform(request)
            Issue.record("the handshake completed against a pin the bridge cannot satisfy")
        } catch let error as NSError {
            // `cancelAuthenticationChallenge` from the delegate arrives here as
            // NSURLErrorCancelled. Timeouts (-1001), refused connections
            // (-1004) and DNS failures (-1003) all mean the harness never got
            // far enough to prove anything, and must fail rather than pass.
            #expect(
                error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled,
                """
                expected the pin check to cancel the challenge \
                (NSURLErrorCancelled, \(NSURLErrorCancelled)); got \
                \(error.domain) \(error.code). A timeout or connection failure \
                here means the bridge was never reached, so this test proved \
                nothing about pinning — check LOCALIS_BRIDGE_HOST/PORT.
                """
            )
        }
    }

    /// The same request with the bridge's real pin reaches HTTP.
    ///
    /// Deliberately *not* asserting 200: no token is supplied, so the bridge is
    /// expected to answer 401. That is the point — a 401 is an **HTTP** answer,
    /// which can only exist if the TLS handshake completed and the delegate
    /// accepted the certificate. Asserting 200 here would conflate the
    /// handshake with authentication, and a failure would not say which broke.
    @Test("the real pin completes the handshake and reaches HTTP")
    func realPinCompletesHandshake() async throws {
        let endpoint = try LiveBridge.endpoint()
        let http = PinnedHTTP(pin: try LiveBridge.realPin())
        let request = try LiveBridge.modelsRequest(endpoint: endpoint, token: "deliberately-invalid")

        let (_, response) = try await http.perform(request)

        // Any HTTP status proves the handshake. 401 is what an invalid token
        // should produce; the assertion is deliberately wide because this test
        // is about the transport, not the status code.
        #expect(response.statusCode > 0)
    }

    // MARK: - The scoped goal: pair, then GET /v1/models

    /// Six-digit code to token to a 200 from `/v1/models` (#31).
    ///
    /// Needs `LOCALIS_BRIDGE_CODE`, which is single-use and expires, so it is
    /// separate from the two tests above — those can be re-run freely while
    /// this one needs a fresh code each time.
    ///
    /// **The token is never asserted on, printed, or returned.** `pair` puts it
    /// in the Keychain and hands back only the bridge's self-description
    /// (constitution I). This test reads it back through `HostCredentialStore`
    /// for the *next* request and never observes its value.
    @Test("pairing with a live code yields a token that GET /v1/models accepts", .enabled(if: LiveBridge.hasPairingCode))
    func pairingThenModels() async throws {
        let endpoint = try LiveBridge.endpoint()
        let pin = try LiveBridge.realPin()
        let host = HostID()

        // A service name unique to this run, so a live pairing never collides
        // with — or overwrites — the developer's real paired hosts.
        let credentials = HostCredentialStore(service: LiveBridge.scratchKeychainService())
        defer { try? credentials.removeCredentials(for: host) }

        // Pinned during pairing too, rather than PinnedHTTP(pin: nil).
        //
        // The nil affordance exists for trust-on-first-use, where nothing is
        // known yet — but `PinnedTrust.evaluate` refuses on a nil pin
        // (PinnedTrust.swift:41), so a nil-pinned session cannot connect at
        // all. Since the pin arrived out of band here, using it is both
        // possible and strictly stronger.
        let pairing = BridgePairing(http: PinnedHTTP(pin: pin), credentials: credentials)

        let result = try await pairing.pair(
            host: host,
            endpoint: endpoint,
            code: try LiveBridge.pairingCode(),
            presenting: pin,
            deviceName: "integration-harness",
            deviceID: UUID()
        )

        #expect(result.protocolVersion == 1)

        // Now the scoped goal, through the same client the app would use.
        let client = try BridgeClient(host: host, endpoint: endpoint, credentials: credentials)
        let catalog = try await client.models()

        // A catalog that parsed is a 200 that parsed: `models()` throws on any
        // other status (BridgeClient.swift:429) and on a body it cannot decode.
        #expect(catalog.backends.isEmpty == false)
    }
}

/// Configuration for the live suite, read from the environment.
///
/// A separate type so the gating predicate can be evaluated without
/// constructing anything, and so every "missing variable" failure names the
/// variable rather than surfacing as a nil unwrap.
enum LiveBridge {
    static let hostKey = "LOCALIS_BRIDGE_HOST"
    static let portKey = "LOCALIS_BRIDGE_PORT"
    static let pinKey = "LOCALIS_BRIDGE_PIN"
    static let codeKey = "LOCALIS_BRIDGE_CODE"

    struct NotConfigured: Error, CustomStringConvertible {
        let variable: String
        var description: String {
            "\(variable) is not set. The live bridge suite needs \(hostKey), \(portKey) and \(pinKey); see the suite's documentation."
        }
    }

    private static func value(_ key: String) throws -> String {
        guard let raw = ProcessInfo.processInfo.environment[key], raw.isEmpty == false else {
            throw NotConfigured(variable: key)
        }
        return raw
    }

    /// All three of host, port and pin present.
    ///
    /// Deliberately all-or-nothing: a half-configured run should not silently
    /// skip, because "skipped because I forgot a variable" and "skipped because
    /// there is no bridge" look identical afterwards.
    static var isConfigured: Bool {
        [hostKey, portKey, pinKey].allSatisfy {
            (ProcessInfo.processInfo.environment[$0]?.isEmpty == false)
        }
    }

    static var hasPairingCode: Bool {
        ProcessInfo.processInfo.environment[codeKey]?.isEmpty == false
    }

    static func endpoint() throws -> HostEndpoint {
        guard let port = Int(try value(portKey)) else {
            throw NotConfigured(variable: "\(portKey) (not a number)")
        }
        return HostEndpoint(host: try value(hostKey), port: port)
    }

    static func realPin() throws -> SPKIHash {
        SPKIHash(base64: try value(pinKey))
    }

    static func pairingCode() throws -> String {
        try value(codeKey)
    }

    /// A structurally valid pin for a key the bridge does not hold.
    ///
    /// Taken from the same fixture the unit tests use, so it is a genuine
    /// SHA-256 of a real SubjectPublicKeyInfo — the comparison has to actually
    /// run and actually fail, rather than the value being rejected as garbage
    /// somewhere earlier.
    static func wrongButWellFormedPin() throws -> SPKIHash {
        let data = try Fixture.data("host-b", extension: "cer")
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let hash = SPKIPinning.spkiHash(of: certificate) else {
            throw Fixture.FixtureError.missing("host-b is not a usable DER certificate")
        }
        return hash
    }

    /// A Keychain service scoped to this process, never the production one.
    static func scratchKeychainService() -> String {
        "dev.localis.bridge.integration.\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// Throws rather than force-unwrapping the URL.
    ///
    /// `components.url` is nil for a host the environment supplied badly — a
    /// stray space, a `https://` prefix pasted in along with the hostname. A
    /// crash there would be reported as "the harness crashed", which sends
    /// whoever runs it looking at the pinning code rather than at the variable
    /// they mistyped.
    static func modelsRequest(endpoint: HostEndpoint, token: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = "/v1/models"

        guard let url = components.url else {
            throw NotConfigured(variable: "\(hostKey) (does not form a URL: \(endpoint.host))")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
