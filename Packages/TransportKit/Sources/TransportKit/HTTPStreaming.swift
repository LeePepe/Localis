import Foundation
import LocalisModels

/// Performs one HTTP request and hands back the response head immediately,
/// with the body arriving as byte chunks afterwards.
///
/// Separate from `HTTPPerforming` because a streamed turn needs the head
/// *before* the body: `x-localis-turn-id` is what makes the turn resumable, and
/// a client that waits for `URLSession.data(for:)` to return has no id to record
/// until the stream is already over — exactly the case background resume exists
/// for (contract §3.3).
///
/// A seam for the same reason as `HTTPPerforming`: chunk boundaries are where
/// the interesting failures live, and no live socket will reproduce them on
/// demand.
protocol HTTPStreaming: Sendable {
    func stream(_ request: URLRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<[UInt8], Error>)
}

/// A response's status and headers, with the body still in flight.
struct HTTPResponseHead: Sendable, Hashable {
    let status: Int

    /// Lower-cased at construction. HTTP header names are case-insensitive and
    /// proxies rewrite their casing freely — a case-sensitive lookup here would
    /// silently make every turn unresumable behind one such proxy.
    private let headers: [String: String]

    init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    init(_ response: HTTPURLResponse) {
        self.init(
            status: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [:]) { result, entry in
                guard let name = entry.key as? String, let value = entry.value as? String else { return }
                result[name] = value
            }
        )
    }

    func value(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Wire names for the headers this client reads and writes (contract §0, §3).
enum BridgeHeader {
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let protocolVersion = "x-localis-protocol"
    static let sessionID = "x-localis-session-id"
    static let workspace = "x-localis-workspace"
    static let turnID = "x-localis-turn-id"
    static let resumeFrom = "x-localis-resume-from"
}

extension PinnedHTTP: HTTPStreaming {
    func stream(
        _ request: URLRequest
    ) async throws -> (HTTPResponseHead, AsyncThrowingStream<[UInt8], Error>) {
        // `delegate:` is a compile-time guard, not the fix itself. Measured
        // against the real bridge: what actually routes the trust challenge here
        // is `PinnedSessionDelegate` conforming to `URLSessionTaskDelegate` —
        // drop this argument and keep the conformance and the pin is still
        // enforced; drop the conformance and the handshake fails as -1202 with
        // the delegate never consulted (#32).
        //
        // It stays because it is what makes the two inseparable: this argument
        // will not type-check without the conformance, so removing the
        // conformance breaks the build rather than silently unpinning every
        // streamed request — which is the failure mode that made #32 invisible.
        // Passing the session's own delegate rather than a fresh one keeps both
        // paths judged by one pin.
        let (bytes, response) = try await session.bytes(for: request, delegate: pinnedDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw LocalisError.malformedResponse
        }

        return (HTTPResponseHead(http), Self.chunks(of: bytes))
    }

    /// Regroups `URLSession`'s byte-at-a-time sequence into line-sized chunks.
    ///
    /// Flushing on `\n` rather than on a fixed size keeps SSE frames arriving as
    /// soon as they are complete: a size-based buffer would hold the last frame
    /// of a reply until enough further bytes arrived to fill it — which, at the
    /// end of a turn, is never.
    ///
    /// Framing itself is still `SSEParser`'s job. These chunks carry no promise
    /// of alignment, and the parser is written for exactly that.
    private static func chunks(of bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var pending: [UInt8] = []
                do {
                    for try await byte in bytes {
                        pending.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }
                        continuation.yield(pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                    // Whatever the connection ended mid-line. Dropping it here
                    // would hide a truncated frame from the parser, which is the
                    // one place that knows an unterminated frame is not a frame.
                    if !pending.isEmpty { continuation.yield(pending) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
