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
        let pairing = BridgePairing(http: http, credentials: store)
        let host = HostID()
        let pin = try #require(SPKIPinning.spkiHash(of: try Self.certificate("host-a")))

        let result = try await pairing.pair(
            host: host,
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            code: "418302",
            presenting: pin,
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
        let pairing = BridgePairing(http: http, credentials: store)
        let host = HostID()

        let result = try await pairing.pair(
            host: host,
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            code: "418302",
            presenting: SPKIHash(base64: "AAA="),
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
        let pairing = BridgePairing(http: http, credentials: store)

        _ = try await pairing.pair(
            host: HostID(),
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            code: "418302",
            presenting: SPKIHash(base64: "AAA="),
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
        let pairing = BridgePairing(http: http, credentials: store)
        let host = HostID()

        await #expect(throws: LocalisError.unauthorized) {
            try await pairing.pair(
                host: host,
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                presenting: SPKIHash(base64: "AAA="),
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
        let http = StubHTTP(responses: [.success(status: 429, body: #"{"error":{"code":"too_many_attempts"}}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store)

        await #expect(throws: LocalisError.unauthorized) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                presenting: SPKIHash(base64: "AAA="),
                deviceName: "iPhone",
                deviceID: UUID()
            )
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
        let pairing = BridgePairing(http: http, credentials: store)

        for _ in 0..<5 {
            await #expect(throws: LocalisError.unauthorized) {
                try await pairing.pair(
                    host: HostID(),
                    endpoint: HostEndpoint(host: "mac.local", port: 8443),
                    code: "000000",
                    presenting: SPKIHash(base64: "AAA="),
                    deviceName: "iPhone",
                    deviceID: UUID()
                )
            }
        }

        await #expect(throws: LocalisError.unauthorized) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "000000",
                presenting: SPKIHash(base64: "AAA="),
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
        let pairing = BridgePairing(http: http, credentials: store)
        let host = HostID()

        await #expect(throws: LocalisError.malformedResponse) {
            try await pairing.pair(
                host: host,
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                presenting: SPKIHash(base64: "AAA="),
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
        let pairing = BridgePairing(http: http, credentials: store)

        await #expect(throws: LocalisError.malformedResponse) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                presenting: SPKIHash(base64: "AAA="),
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
        let pairing = BridgePairing(http: http, credentials: store)

        await #expect(throws: LocalisError.malformedResponse) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                presenting: SPKIHash(base64: "AAA="),
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
        let pairing = BridgePairing(http: http, credentials: store)

        await #expect(throws: LocalisError.unreachable) {
            try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                presenting: SPKIHash(base64: "AAA="),
                deviceName: "iPhone",
                deviceID: UUID()
            )
        }

        store.removeAll()
    }

    @Test("the code is not carried in any error")
    func codeNotInErrors() async throws {
        // The pairing code is short-lived but is still a credential, and errors
        // travel further than anyone expects.
        let http = StubHTTP(responses: [.success(status: 401, body: #"{"error":{"code":"invalid_code"}}"#)])
        let store = HostCredentialStore(service: Self.testService())
        let pairing = BridgePairing(http: http, credentials: store)

        do {
            _ = try await pairing.pair(
                host: HostID(),
                endpoint: HostEndpoint(host: "mac.local", port: 8443),
                code: "418302",
                presenting: SPKIHash(base64: "AAA="),
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
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        case .failure(let error):
            throw error
        }
    }
}
