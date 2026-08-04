import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The HTTPS listener.
///
/// **There is no plaintext path.** The TLS handler is installed unconditionally
/// in the channel initialiser — not behind a flag, an environment variable, or
/// a "development mode". Constitution §V is a property of this file's shape
/// rather than of a check performed at startup: a bypass would have to be added
/// as new code, not enabled by configuration.
///
/// Raw NIO rather than a web framework because of the streaming. A turn's first
/// token has to reach the phone as soon as the CLI emits it, and a framework
/// that buffers response bodies — most do, to set `Content-Length` — converts
/// that into "the whole reply arrives at once when the turn ends". That is the
/// difference between a chat app and a form submission.
public final class BridgeServer: Sendable {
    private let identity: BridgeIdentity
    private let handler: any BridgeHandling
    private let group: MultiThreadedEventLoopGroup

    public init(identity: BridgeIdentity, handler: any BridgeHandling) {
        self.identity = identity
        self.handler = handler
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Binds and serves until `stop()`.
    ///
    /// - Returns: the port actually bound. Passing 0 for `port` and reading the
    ///   result back is how the tests get a free port without racing another
    ///   process for a fixed one.
    @discardableResult
    public func start(host: String = "0.0.0.0", port: Int) async throws -> Int {
        let tls = try tlsConfiguration()
        let sslContext = try NIOSSLContext(configuration: tls)
        let handler = self.handler

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // TLS first in the pipeline, so nothing downstream ever sees a
                // byte that did not come through it.
                channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
                    .flatMap {
                        channel.pipeline.configureHTTPServerPipeline()
                    }
                    .flatMap {
                        channel.pipeline.addHandler(HTTPRequestHandler(handler: handler))
                    }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            // Nagle's algorithm holds a small write back waiting for company.
            // On an SSE stream every frame is a small write, and the delay it
            // buys is paid directly in visible latency per token.
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.autoRead, value: true)

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel.withLockedValue { $0 = channel }

        guard let bound = channel.localAddress?.port else {
            throw Failure.noBoundPort
        }
        return bound
    }

    public func stop() async throws {
        let channel = self.channel.withLockedValue { value in
            defer { value = nil }
            return value
        }
        try? await channel?.close()
        try await group.shutdownGracefully()
    }

    private let channel = NIOLockedValueBox<Channel?>(nil)

    /// TLS configured from the bridge's own certificate.
    ///
    /// `certificateVerification` is `.none` because that setting concerns
    /// *client* certificates, which this protocol does not use — the client
    /// authenticates with a bearer token, and the server authenticates with the
    /// pinned key. Turning it on would demand a certificate no phone has.
    private func tlsConfiguration() throws -> TLSConfiguration {
        let certificate = try NIOSSLCertificate(
            bytes: [UInt8](identity.certificatePEM.utf8),
            format: .pem
        )
        let key = try NIOSSLPrivateKey(
            bytes: [UInt8](identity.privateKeyPEM.utf8),
            format: .pem
        )

        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(key)
        )
        // The client is a current iOS build, not an arbitrary browser, so there
        // is no legacy peer to accommodate — and TLS 1.2 offers cipher suites
        // worth not offering.
        configuration.minimumTLSVersion = .tlsv13

        return configuration
    }

    public enum Failure: Error {
        case noBoundPort
    }
}

// MARK: - Per-connection HTTP

/// Accumulates one request, dispatches it, writes the response.
///
/// `@unchecked Sendable` and mutable state without a lock: every method here is
/// called on this channel's event loop and on no other, which is NIO's own
/// contract for a `ChannelHandler`. A lock would be dead weight that suggests
/// otherwise.
private final class HTTPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: any BridgeHandling

    private var head: HTTPRequestHead?
    private var body: [UInt8] = []

    /// A request body larger than this is refused before it is buffered.
    ///
    /// A turn carries a conversation, not a file. Without a cap, one client can
    /// make this process allocate until it is killed — and the bridge dying
    /// takes every other conversation on the machine with it.
    private static let maximumBodyBytes = 8 * 1024 * 1024
    private var bodyTooLarge = false

    init(handler: any BridgeHandling) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = []
            bodyTooLarge = false

        case .body(var buffer):
            guard !bodyTooLarge else { return }
            guard body.count + buffer.readableBytes <= Self.maximumBodyBytes else {
                // Flagged rather than closed immediately: answering 413 tells
                // the client what happened, where a dropped connection reads as
                // a network fault and invites a retry of the same request.
                bodyTooLarge = true
                body = []
                return
            }
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])

        case .end:
            guard let head else { return }
            self.head = nil

            let request = BridgeRequest(
                method: head.method.rawValue,
                uri: head.uri,
                headers: Dictionary(
                    head.headers.map { ($0.name, $0.value) },
                    uniquingKeysWith: { first, _ in first }
                ),
                body: body
            )
            body = []

            let response: BridgeResponse? = bodyTooLarge
                ? .error(status: 413, code: "request_too_large")
                : nil
            bodyTooLarge = false

            dispatch(request, precomputed: response, on: context)
        }
    }

    /// Runs the handler off the event loop, then writes back on it.
    private func dispatch(
        _ request: BridgeRequest,
        precomputed: BridgeResponse?,
        on context: ChannelHandlerContext
    ) {
        let handler = self.handler
        let channel = context.channel
        let keepAlive = request.header("Connection")?.lowercased() != "close"

        Task {
            // Written out rather than with `??`: the right-hand side is async,
            // and `??` evaluates it inside an autoclosure that cannot await.
            let response: BridgeResponse
            if let precomputed {
                response = precomputed
            } else {
                response = await handler.respond(to: request)
            }
            await Self.write(response, to: channel, keepAlive: keepAlive)
        }
    }

    private static func write(
        _ response: BridgeResponse,
        to channel: Channel,
        keepAlive: Bool
    ) async {
        switch response {
        case .complete(let status, let headers, let body):
            await writeComplete(status: status, headers: headers, body: body, to: channel, keepAlive: keepAlive)

        case .stream(let status, let headers, let events):
            await writeStream(status: status, headers: headers, events: events, to: channel)
        }
    }

    private static func writeComplete(
        status: Int,
        headers: [String: String],
        body: [UInt8],
        to channel: Channel,
        keepAlive: Bool
    ) async {
        var httpHeaders = HTTPHeaders(headers.map { ($0.key, $0.value) })
        httpHeaders.replaceOrAdd(name: "Content-Length", value: String(body.count))
        httpHeaders.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        addProtocolVersion(to: &httpHeaders)

        let head = HTTPResponseHead(
            version: .http1_1,
            status: .init(statusCode: status),
            headers: httpHeaders
        )

        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            let part = HTTPServerResponsePart.body(IOData.byteBuffer(buffer))
            _ = try? await channel.writeAndFlush(part).get()
        }
        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()

        if !keepAlive { try? await channel.close() }
    }

    /// Writes an SSE stream, flushing every frame as it arrives.
    ///
    /// **Chunked with no `Content-Length`**, and flushed per frame. Buffering
    /// here would be invisible in any test that reads the whole response and
    /// then asserts on it — and would show up in use as a reply that appears
    /// all at once, seconds late.
    private static func writeStream(
        status: Int,
        headers: [String: String],
        events: BridgeEventStream,
        to channel: Channel
    ) async {
        var httpHeaders = HTTPHeaders(headers.map { ($0.key, $0.value) })
        httpHeaders.replaceOrAdd(name: "Content-Type", value: "text/event-stream")
        // An intermediary caching an event stream would serve one user's reply
        // to another. Unlikely on a LAN; free to prevent.
        httpHeaders.replaceOrAdd(name: "Cache-Control", value: "no-cache")
        httpHeaders.replaceOrAdd(name: "Connection", value: "close")
        httpHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        addProtocolVersion(to: &httpHeaders)

        let head = HTTPResponseHead(
            version: .http1_1,
            status: .init(statusCode: status),
            headers: httpHeaders
        )
        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()

        do {
            for try await frame in events {
                var buffer = channel.allocator.buffer(capacity: frame.count)
                buffer.writeBytes(frame)
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
            }
        } catch {
            // The stream failed mid-turn. There is no way to change a status
            // already sent, so the connection closes without `[DONE]` — which
            // the client reads as `connectionLost` and keeps the partial text.
            // That is the honest outcome: some of the answer did arrive.
        }

        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        try? await channel.close()
    }

    /// Every response carries the protocol version.
    ///
    /// The client compares it on *every* response and reports which side needs
    /// upgrading. Omitting it is treated as compatible, so a missing header
    /// would not fail — it would just make a real version mismatch surface as
    /// unexplained parse errors later.
    private static func addProtocolVersion(to headers: inout HTTPHeaders) {
        headers.replaceOrAdd(name: "x-localis-protocol", value: String(BridgeProtocol.version))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Includes TLS handshake failures, which are routine here: a phone that
        // has not paired, or whose pin no longer matches, fails exactly this
        // way. Nothing is logged — the peer address and handshake details are
        // not ours to record (constitution §I) — and the channel closes.
        context.close(promise: nil)
    }
}

/// Protocol version this bridge speaks (contract §0).
public enum BridgeProtocol {
    public static let version = 1
}
