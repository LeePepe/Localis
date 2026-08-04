import Foundation
import LocalisModels

/// Pairs this device with one bridge (contract §1, T023).
///
/// Pairing is the only moment a certificate is accepted without a pin to check
/// it against, so it is also the moment the pin for every later connection is
/// recorded. Both halves — the bearer token and the SPKI — are written under
/// this host's key and no other (FR-028).
///
/// **Written only on success.** A pin stored after a failed attempt is a trust
/// anchor for a machine we never authenticated to, and it would sit there
/// looking exactly like a legitimate one.
public struct BridgePairing: Sendable {
    /// What the bridge told us about itself. No credential: the token goes
    /// straight to the Keychain and is never returned to a caller that might
    /// log it.
    public struct Result: Hashable, Sendable {
        public let bridgeName: String
        public let protocolVersion: Int
        /// Optional per Amendment A §1.6 — older bridges omit it, and the
        /// client falls back to SPKI matching.
        public let bridgeID: String?
    }

    private let http: any HTTPPerforming
    private let credentials: HostCredentialStore

    init(http: any HTTPPerforming, credentials: HostCredentialStore) {
        self.http = http
        self.credentials = credentials
    }

    /// Pairs with the bridge at `endpoint` using the six-digit code shown on
    /// the Mac.
    ///
    /// - Parameters:
    ///   - host: the locally generated id this machine will keep for life.
    ///   - presenting: the SPKI of the certificate the bridge presented on this
    ///     connection. Recorded as the pin, and checked on every connection
    ///     afterwards.
    /// - Throws: `LocalisError.pairingCodeRejected` for a wrong or expired code
    ///   (the session on the Mac is still live, so re-reading it works);
    ///   `.pairingSessionExpired` once five failures have invalidated the
    ///   request, which no retry from this screen can undo; `.unreachable` when
    ///   the Mac did not answer; `.malformedResponse` for a reply we cannot use.
    public func pair(
        host: HostID,
        endpoint: HostEndpoint,
        code: String,
        presenting spki: SPKIHash,
        deviceName: String,
        deviceID: UUID
    ) async throws -> Result {
        let request = try Self.request(endpoint: endpoint, code: code, deviceName: deviceName, deviceID: deviceID)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.perform(request)
        } catch {
            // `TransportFailure` decides, rather than a catch-all here, so this
            // path and the streamed one cannot answer differently for the same
            // failure. Answering `.unreachable` for everything told a user
            // whose host presented an unpinned certificate that their Mac was
            // asleep — during pairing, the one moment the pin is established
            // (#34).
            //
            // What it cannot place stays `.unreachable` carrying the OS's
            // `domain` and `code`, and that matters more here than anywhere
            // else: pairing is the first time this device talks to this Mac, so
            // the user has no working state to compare against. `-1202` in a
            // log is the difference between a refused certificate and a Mac
            // that is genuinely asleep.
            throw TransportFailure.classify(error)
        }

        try Self.checkStatus(response.statusCode)

        let result = try Self.decode(data)

        // Order matters: the token first, so a Keychain failure cannot leave a
        // pin behind for a host with no way to authenticate.
        try credentials.saveToken(result.token, for: host)
        try credentials.savePin(spki, for: host)

        return Result(
            bridgeName: result.bridgeName,
            protocolVersion: result.protocolVersion,
            bridgeID: result.bridgeID
        )
    }

    // MARK: - Request

    private static func request(
        endpoint: HostEndpoint,
        code: String,
        deviceName: String,
        deviceID: UUID
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = Self.pairPath

        guard let url = components.url else {
            throw LocalisError.invalidInput(field: "endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(Self.protocolVersion), forHTTPHeaderField: "x-localis-protocol")
        // No `Authorization` — this call is what produces the token.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "device_name": deviceName,
            "device_id": deviceID.uuidString,
        ])

        return request
    }

    private static let pairPath = "/localis/v1/pair"
    static let protocolVersion = 1

    // MARK: - Response

    private static func checkStatus(_ status: Int) throws {
        switch status {
        case 200:
            return
        case 401:
            // A wrong or expired code. The pairing session on the Mac is still
            // live, so re-reading the six digits is the action that works.
            throw LocalisError.pairingCodeRejected
        case 429:
            // The session was invalidated after five failures (spec.md:62). The
            // code on the Mac's screen is dead, so unlike 401 the user has to
            // start pairing again over there — retyping cannot succeed.
            //
            // These shared `unauthorized` until `LocalisError` gained the two
            // cases: the fifth wrong attempt read "wrong code, try again",
            // advice that is guaranteed to fail.
            throw LocalisError.pairingSessionExpired
        case 503:
            // Contract §6: the Mac answered, and answered *usefully* — it is
            // just not able to pair right now. `default` used to swallow this
            // into `malformedResponse`, which sends the user to debug a reply
            // that was well-formed, and drops the retry affordance §6 requires.
            //
            // The reason code is deliberately nil rather than read off the
            // body. §6's `unavailable_reason` describes which *backend* is
            // unavailable, and pairing precedes any backend choice — inventing a
            // per-backend reason here would render wording about a thing the
            // user has not picked yet.
            throw LocalisError.backendUnavailable(reason: nil)
        default:
            throw LocalisError.malformedResponse
        }
    }

    /// The decoded body, token included — internal, so the token cannot escape
    /// past `pair`.
    private struct Decoded {
        let token: String
        let bridgeName: String
        let protocolVersion: Int
        let bridgeID: String?
    }

    /// Reads the response by key rather than through `Codable`.
    ///
    /// The protocol is explicitly additive (Amendment A §1.6): a synthesised
    /// struct would either reject a bridge that added a field or need a custom
    /// decoder to tolerate one.
    private static func decode(_ data: Data) throws -> Decoded {
        guard let json = JSONValue(jsonData: data),
              let token = json["token"]?.stringValue?.trimmed,
              !token.isEmpty else {
            // A blank token would be sent as the bearer on every later request
            // and surface as a mysterious 401 far from here.
            throw LocalisError.malformedResponse
        }

        let name = json["bridge_name"]?.stringValue?.trimmed
        let bridgeID = json["bridge_id"]?.stringValue?.trimmed

        return Decoded(
            token: token,
            // A nameless bridge is usable; the caller shows the address instead.
            bridgeName: name?.nonEmpty ?? "",
            protocolVersion: json["protocol"]?.intValue ?? protocolVersion,
            bridgeID: bridgeID?.nonEmpty
        )
    }
}
