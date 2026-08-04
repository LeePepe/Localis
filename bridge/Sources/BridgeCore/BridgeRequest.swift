import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// One HTTP request, reduced to what a handler needs.
///
/// Header names are lower-cased on the way in. HTTP header names are
/// case-insensitive and clients spell them however they like — a
/// case-sensitive lookup would make `Authorization` and `authorization`
/// different headers, which fails as "unauthorized" rather than as a bug.
public struct BridgeRequest: Sendable {
    public let method: String
    public let uri: String
    public let route: Route
    public let body: [UInt8]

    private let headers: [String: String]

    public init(method: String, uri: String, headers: [String: String], body: [UInt8]) {
        self.method = method
        self.uri = uri
        self.route = Router.route(method: method, uri: uri)
        self.body = body
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The bearer token, or nil when the header is absent or not a bearer.
    ///
    /// The scheme is checked rather than stripped blindly: accepting a bare
    /// token without `Bearer ` would also accept `Basic <base64>`, whose
    /// decoded form an attacker chooses.
    public var bearerToken: String? {
        guard let value = header("Authorization") else { return nil }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return nil }

        let token = String(value.dropFirst(prefix.count))
        return token.isEmpty ? nil : token
    }
}

/// What a handler answers with.
///
/// Two shapes, because the wire has two: a complete body, or a stream that ends
/// when the turn does.
public enum BridgeResponse: Sendable {
    /// Status, headers, and the whole body at once.
    case complete(status: Int, headers: [String: String] = [:], body: [UInt8] = [])
    /// An SSE stream. The head goes out immediately — the iOS client reads
    /// `x-localis-turn-id` off it before the first event arrives, and a turn
    /// whose id shows up only at the end is a turn that cannot be resumed.
    case stream(status: Int, headers: [String: String] = [:], events: BridgeEventStream)

    /// The status this response carries, whichever shape it is.
    ///
    /// Both cases have one; without this the log would have to switch on the
    /// shape, and could report a stream's status only once the turn had ended.
    public var status: Int {
        switch self {
        case .complete(let status, _, _): status
        case .stream(let status, _, _): status
        }
    }

    public static func json(
        status: Int,
        headers: [String: String] = [:],
        object: [String: any Sendable]
    ) -> BridgeResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { [UInt8]($0) } ?? []

        return .complete(
            status: status,
            headers: headers.merging(["Content-Type": "application/json"]) { existing, _ in existing },
            body: body
        )
    }

    /// The error envelope from contract §6.
    ///
    /// **`code` is the only field a client is allowed to act on.** A message is
    /// accepted here but is for humans reading a bridge log — the iOS client
    /// deliberately never reads it, because messages carry absolute paths
    /// (constitution §I).
    public static func error(
        status: Int,
        code: String,
        message: String? = nil,
        headers: [String: String] = [:]
    ) -> BridgeResponse {
        var error: [String: any Sendable] = ["code": code]
        if let message { error["message"] = message }

        return .json(status: status, headers: headers, object: ["error": error])
    }
}

/// A stream of already-encoded SSE frames.
public typealias BridgeEventStream = AsyncThrowingStream<[UInt8], any Error>

/// Turns a request into a response.
public protocol BridgeHandling: Sendable {
    func respond(to request: BridgeRequest) async -> BridgeResponse
}
