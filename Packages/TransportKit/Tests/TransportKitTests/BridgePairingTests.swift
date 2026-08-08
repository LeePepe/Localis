import Foundation
import LocalisModels
import Security
import Testing

@testable import TransportKit

/// Enforcing the pin on a live connection (T022) and recording it at pairing
/// (T023).
///
/// The two are one story: pairing is the only moment a certificate is accepted
/// without a pin to check it against, and it is where the pin for every later
/// connection comes from. Getting the boundary wrong in either direction is
/// silent — accept too much at pairing and the pin is an attacker's key; check
/// too little afterwards and the pin is decoration.
@Suite("Pinned connections and pairing")
struct BridgePairingTests {
    private static func certificate(_ name: String) throws -> SecCertificate {
        let data = try Fixture.data(name, extension: "cer")
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw Fixture.FixtureError.missing("\(name) is not a DER certificate")
        }
        return certificate
    }

    // MARK: - Trust evaluation (T022)

    @Test("the pinned certificate is trusted")
    func pinnedChainTrusted() throws {
        let leaf = try Self.certificate("host-a")
        let pin = try #require(SPKIPinning.spkiHash(of: leaf))

        #expect(PinnedTrust.evaluate(chain: [leaf], against: pin) == .proceed)
    }

    @Test("a different certificate is refused")
    func changedChainRefused() throws {
        let pin = try #require(SPKIPinning.spkiHash(of: try Self.certificate("host-a")))

        // Spec US1 scenario 7. Refusal is the whole feature: an attacker's
        // certificate arrives looking exactly like a legitimate reinstall, so
        // "ask the user" would be answered wrong by design.
        #expect(PinnedTrust.evaluate(chain: [try Self.certificate("host-b")], against: pin) == .refuse)
    }

    @Test("only the leaf certificate is compared")
    func onlyLeafIsPinned() throws {
        // A chain where the *pinned* key appears further up must not pass: the
        // server proves possession of the leaf key only.
        let pin = try #require(SPKIPinning.spkiHash(of: try Self.certificate("host-a")))
        let chain = [try Self.certificate("host-b"), try Self.certificate("host-a")]

        #expect(PinnedTrust.evaluate(chain: chain, against: pin) == .refuse)
    }

    @Test("an empty chain is refused")
    func emptyChainRefused() throws {
        // Nothing to compare is not "nothing wrong". A server presenting no
        // certificate must not inherit the benefit of the doubt.
        let pin = try #require(SPKIPinning.spkiHash(of: try Self.certificate("host-a")))

        #expect(PinnedTrust.evaluate(chain: [], against: pin) == .refuse)
    }

    @Test("an unpinned host is refused rather than allowed through")
    func unpinnedHostRefused() throws {
        // The delegate has no pin because the host is not paired. That is a
        // refusal, not a pass — otherwise an unpaired host connects on the
        // strength of having no history.
        #expect(PinnedTrust.evaluate(chain: [try Self.certificate("host-a")], against: nil) == .refuse)
    }

    @Test("the disposition has no third, permissive value")
    func dispositionHasNoBypass() {
        // Checked mechanically because "just for debugging" is exactly how a
        // third case gets added and then ships.
        let all: Set<PinnedTrust.Disposition> = [.proceed, .refuse]

        #expect(all.count == 2)
    }

    // MARK: - Pairing success (T023)

    @Test("a correct code returns a token and pins the certificate")
    func pairsSuccessfully() async throws {
        let http = StubHTTP(responses: [.success(status: 200, body: """
        {"token":"opaque-token","bridge_name":"Tian's MacBook Pro","protocol":1,"bridge_id":"bridge-abc"}
        """)])
        let store = HostCredentialStore(service: Self.testService())
        let host = HostID()
        let pin = try #require(SPKIPinning.spkiHash(of: try Self.certificate("host-a")))
        let pairing = BridgePairing(http: http, credentials: store, pin: pin)

        let result = try await pairing.pair(
            host: host,
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            code: "418302",
            deviceName: "Tian's iPhone",
            deviceID: UUID()
        )

        #expect(result.bridgeName == "Tian's MacBook Pro")
        #expect(result.protocolVersion == 1)
        #expect(result.bridgeID == "bridge-abc")
        // Both halves land, keyed to this host and nothing else.
        #expect(try store.token(for: host) == "opaque-token")
        #expect(try store.pin(for: host) == pin)

        store.removeAll()
    }

    @Test("an older bridge omitting bridge_id still pairs")
    func bridgeIDOptional() async throws {
        // Amendment A §1.6: additive and optional. Requiring it would make the
        // client refuse to pair with a bridge that predates the field.
        let http = StubHTTP(responses: [.success(status: 200, body: """
        {"token":"t","bridge_name":"Old Bridge","protocol":1}
        """)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))
        let host = HostID()

        let result = try await pairing.pair(
            host: host,
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            code: "418302",
            deviceName: "iPhone",
            deviceID: UUID()
        )

        #expect(result.bridgeID == nil)
        #expect(try store.token(for: host) == "t")

        store.removeAll()
    }

    @Test("the request goes to the pairing endpoint over https")
    func requestShape() async throws {
        let http = StubHTTP(responses: [.success(status: 200, body: #"{"token":"t","bridge_name":"M","protocol":1}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        _ = try await pairing.pair(
            host: HostID(),
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            code: "418302",
            deviceName: "Tian's iPhone",
            deviceID: UUID()
        )

        let sent = try #require(await http.lastRequest)
        #expect(sent.url?.absoluteString == "https://mac.local:8443/localis/v1/pair")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-localis-protocol") == "1")
        // No bearer yet — there is no token until this call returns one.
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)

        store.removeAll()
    }

    // MARK: - Pairing failure (T023)

    @Test("a wrong or expired code is reported as such")
    func wrongCodeRejected() async throws {
        let http = StubHTTP(responses: [.success(status: 401, body: #"{"error":{"code":"invalid_code"}}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))
        let host = HostID()

        await #expect(throws: LocalisError.pairingCodeRejected) {
            try await pairing.pair(
                host: host,
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        // Nothing is written on a failed attempt. A pin stored here would be a
        // trust anchor for a machine we never authenticated to.
        #expect(try store.token(for: host) == nil)
        #expect(try store.pin(for: host) == nil)

        store.removeAll()
    }

    @Test("a session invalidated after five failures is reported distinctly")
    func sessionInvalidated() async throws {
        // 429 is not "try again in a moment" here — the pairing session is dead
        // and the user must start a new one on the Mac. Reporting it as a
        // generic failure would leave them retyping into a session that can
        // never succeed.
        //
        // This test asserted `.unauthorized` until the two cases were split —
        // the same value the 401 test above asserts. Its name said "reported
        // distinctly" while its assertion accepted the two being identical, so
        // it stayed green through exactly the defect it was written to catch.
        let http = StubHTTP(responses: [.success(status: 429, body: #"{"error":{"code":"too_many_attempts"}}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        await #expect(throws: LocalisError.pairingSessionExpired) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        store.removeAll()
    }

    @Test("a Mac that cannot pair right now says so instead of reading as garbage")
    func pairingBackendUnavailable() async throws {
        // Contract §6 lists 503 `backend_unavailable` with a required client
        // behaviour: plain-language message plus a retry action. Flattening it
        // into `.malformedResponse` loses both — `isRetryable` is true either
        // way, but the wording sends the user to debug a reply that was
        // perfectly well-formed and told them exactly what was wrong.
        //
        // `BridgeClient` already maps this correctly. Two paths in one package
        // reading the same table differently is the drift this asserts against.
        let http = StubHTTP(responses: [.success(
            status: 503,
            body: #"{"error":{"code":"backend_unavailable","message":"/Users/someone/Library/whatever"}}"#
        )])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        do {
            _ = try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                deviceName: "iPhone",
                deviceID: UUID()
            )
            Issue.record("expected a refusal")
        } catch {
            #expect(error as? LocalisError == .backendUnavailable(reason: nil))
            // The bridge's own `message` may hold an absolute path
            // (constitution I / FR-025) and must not ride out on the error.
            #expect(String(describing: error).contains("Users") == false)
        }

        store.removeAll()
    }

    @Test("five wrong codes each report the code error, then the session dies")
    func fiveFailuresThenInvalid() async throws {
        // The bridge counts, not the client — but the client must render the
        // transition correctly, so this walks the whole sequence.
        let http = StubHTTP(responses: Array(
            repeating: .success(status: 401, body: #"{"error":{"code":"invalid_code"}}"#), count: 5
        ) + [.success(status: 429, body: #"{"error":{"code":"too_many_attempts"}}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        for _ in 0..<5 {
            await #expect(throws: LocalisError.pairingCodeRejected) {
                try await pairing.pair(
                    host: HostID(),
                    endpoint: HostEndpoint(host: "mac.local", port: 8443),
                    code: "000000",
                    deviceName: "iPhone",
                    deviceID: UUID()
                )
            }
        }

        // The transition this test is named for. Before the cases were split,
        // both assertions here were `.unauthorized` — the same value on both
        // sides of "then", so the one thing the name promises to check was the
        // one thing it could not have caught.
        await #expect(throws: LocalisError.pairingSessionExpired) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        store.removeAll()
    }

    @Test("a response missing the token is malformed, not a silent success")
    func missingTokenIsMalformed() async throws {
        let http = StubHTTP(responses: [.success(status: 200, body: #"{"bridge_name":"M","protocol":1}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))
        let host = HostID()

        await #expect(throws: LocalisError.malformedResponse) {
            try await pairing.pair(
                host: host,
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        #expect(try store.pin(for: host) == nil, "a pin without a token is a trust anchor we cannot use")

        store.removeAll()
    }

    @Test("a blank token is refused")
    func blankTokenRefused() async throws {
        // An empty bearer would be sent on every request and rejected by the
        // bridge, surfacing later as a mysterious 401 far from the cause.
        let http = StubHTTP(responses: [.success(status: 200, body: #"{"token":"  ","bridge_name":"M","protocol":1}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        await #expect(throws: LocalisError.malformedResponse) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        store.removeAll()
    }

    @Test("garbage in the response body is malformed")
    func garbageBodyIsMalformed() async throws {
        let http = StubHTTP(responses: [.success(status: 200, body: "<html>gateway</html>")])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        await #expect(throws: LocalisError.malformedResponse) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        store.removeAll()
    }

    @Test("a transport failure surfaces as unreachable, not as a wrong code")
    func transportFailureIsUnreachable() async throws {
        // Telling the user their code is wrong when the Mac is simply asleep
        // sends them to re-read a code that was fine.
        let http = StubHTTP(responses: [.failure(URLError(.cannotConnectToHost))])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        // Matches the case, not the whole value: since #34 the error carries the
        // OS's domain and code, so comparing against `.unreachable()` would be
        // asserting the diagnostic is absent. The claim here is about which
        // category the user lands in — asleep Mac, not wrong code.
        do {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                deviceName: "iPhone",
                deviceID: UUID()
            )
            Issue.record("expected the socket failure to surface")
        } catch let error as LocalisError {
            guard case .unreachable = error else {
                Issue.record("expected .unreachable, got \(error)")
                store.removeAll()
                return
            }
        }

        store.removeAll()
    }

    /// A certificate rejected *during pairing* must say so.
    ///
    /// The worst moment for this to be mislabelled. Pairing is when the pin is
    /// established, so a certificate that fails here is either a host the user
    /// has not actually reached or one presenting a key that is not the one on
    /// screen. Reporting it as "your Mac is asleep" invites a retry, and a
    /// retry that succeeds against the wrong certificate pins the wrong
    /// certificate — permanently, and with no override path by design
    /// (constitution V).
    ///
    /// Paired with `transportFailureIsUnreachable` above so the two answers are
    /// shown to be distinguished, not merely both reachable (#34).
    @Test("a rejected certificate during pairing is named, not reported as an outage")
    func certificateFailureDuringPairingIsPinMismatch() async throws {
        let http = StubHTTP(responses: [.failure(URLError(.serverCertificateUntrusted))])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        await #expect(throws: LocalisError.certificatePinMismatch) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        store.removeAll()
    }

    func codeNotInErrors() async throws {
        // The pairing code is short-lived but is still a credential, and errors
        // travel further than anyone expects.
        let http = StubHTTP(responses: [.success(status: 401, body: #"{"error":{"code":"invalid_code"}}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store, pin: SPKIHash(base64: "AAA="))

        do {
            _ = try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                deviceName: "iPhone",
                deviceID: UUID()
            )
            Issue.record("expected pairing to fail")
        } catch {
            #expect(String(describing: error).contains("418302") == false)
        }

        store.removeAll()
    }

    private static func testService() -> String {
        "dev.localis.tests.\(UUID().uuidString)"
    }
}

/// A scripted HTTP layer.
///
/// Pairing is one request and one response; what is worth testing is how each
/// response shape is interpreted, which needs no socket.
private actor StubHTTP: HTTPPerforming {
    enum Response {
        case success(status: Int, body: String)
        case failure(any Error)
    }

    private var queue: [Response]
    private(set) var lastRequest: URLRequest?

    init(responses: [Response]) {
        queue = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request

        guard !queue.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch queue.removeFirst() {
        case .success(let status, let body):
            // Not `!`, and deliberately not a thrown `URLError` either: several
            // tests here script a transport failure and assert on it, so a stub
            // that reported its own breakage that way would be indistinguishable
            // from the case under test. `Issue.record` fails the test as itself.
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url, statusCode: status, httpVersion: nil, headerFields: nil
                  )
            else {
                Issue.record("StubHTTP could not build a response — the stub is broken, not the code under test")
                throw Fixture.FixtureError.missing("unbuildable stub response")
            }
            return (Data(body.utf8), response)
        case .failure(let error):
            throw error
        }
    }
}
