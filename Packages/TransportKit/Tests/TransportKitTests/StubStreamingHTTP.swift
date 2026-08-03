import Foundation
import Testing

@testable import TransportKit

/// A scripted streaming HTTP layer.
///
/// Chunk boundaries are the point: real bytes do not arrive frame-aligned, and
/// the bugs that matter here only appear when a frame is cut in the wrong place.
actor StubStreamingHTTP: HTTPStreaming {
    enum Response {
        case stream(status: Int, headers: [String: String], body: [String])
        case streamBytes(status: Int, headers: [String: String], chunks: [[UInt8]])
        case streamThenFail(status: Int, body: [String], error: any Error)
        case failure(any Error)
    }

    private var queue: [Response]
    private(set) var lastRequest: URLRequest?

    init(responses: [Response]) {
        queue = responses
    }

    func stream(
        _ request: URLRequest
    ) async throws -> (HTTPResponseHead, AsyncThrowingStream<[UInt8], Error>) {
        lastRequest = request

        guard !queue.isEmpty else { throw URLError(.badServerResponse) }

        switch queue.removeFirst() {
        case .stream(let status, let headers, let body):
            return (
                HTTPResponseHead(status: status, headers: headers),
                Self.stream(chunks: body.map { Array($0.utf8) }, failingWith: nil)
            )
        case .streamBytes(let status, let headers, let chunks):
            return (
                HTTPResponseHead(status: status, headers: headers),
                Self.stream(chunks: chunks, failingWith: nil)
            )
        case .streamThenFail(let status, let body, let error):
            return (
                HTTPResponseHead(status: status, headers: [:]),
                Self.stream(chunks: body.map { Array($0.utf8) }, failingWith: error)
            )
        case .failure(let error):
            throw error
        }
    }

    private static func stream(
        chunks: [[UInt8]],
        failingWith error: (any Error)?
    ) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: error)
        }
    }
}
