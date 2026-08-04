import Foundation
import Testing

@testable import BridgeCore

/// The HTTPS listener, tested by connecting to it over a real socket.
///
/// **`curl` is the client here, not an in-process harness.** The properties
/// that matter — that TLS is actually negotiated, that a plaintext request is
/// refused, that SSE frames arrive as they are produced rather than at the end
/// — are properties of bytes on a socket. An in-process test that hands a
/// `BridgeRequest` to a handler exercises none of them, and would stay green
/// through a server that never bound a port.
@Suite("BridgeServer — TLS listener", .serialized)
struct BridgeServerTests {
    /// The bridge answers over TLS at all, and the certificate `curl` sees is
    /// the one whose pin we published.
    ///
    /// The second half is what the phone actually does: it does not trust the
    /// certificate, it compares the key. If these two ever diverge, every
    /// paired phone stops connecting with no explanation.
    @Test("serves over TLS with the certificate whose pin we advertise")
    func servesOverTLS() async throws {
        try await withServer(handler: EchoHandler()) { port, identity in
            let response = try Curl.get("https://127.0.0.1:\(port)/v1/models", pin: identity.spkiPin)

            #expect(response.status == 200)
            #expect(response.body.contains("models"))
        }
    }

    /// **Constitution §V.** A plaintext request must not be answered.
    ///
    /// Asserted by speaking HTTP to the port and finding no HTTP response
    /// there: the server sees a client hello that is not one and drops the
    /// connection. There is no configuration under which this test could be
    /// made to pass — which is the point.
    @Test("a plaintext request gets no HTTP response")
    func plaintextRefused() async throws {
        try await withServer(handler: EchoHandler()) { port, _ in
            let result = Curl.raw(["--max-time", "5", "http://127.0.0.1:\(port)/v1/models"])

            #expect(result.exitCode != 0)
            #expect(!result.stdout.contains("HTTP/1.1 200"))
        }
    }

    /// A certificate presenting a different key must fail the pin check.
    ///
    /// This is the negative control for `servesOverTLS`: without it, that test
    /// would also pass against a `--pinnedpubkey` flag that curl silently
    /// ignored, and the pin would be decorative.
    @Test("a mismatched pin refuses the connection")
    func mismatchedPinRefused() async throws {
        let other = try BridgeIdentity.generate()

        try await withServer(handler: EchoHandler()) { port, identity in
            #expect(other.spkiPin != identity.spkiPin)

            let result = Curl.raw([
                "--max-time", "5",
                "--insecure",
                "--pinnedpubkey", "sha256//\(other.spkiPin)",
                "https://127.0.0.1:\(port)/v1/models",
            ])

            // curl 90 is CURLE_SSL_PINNEDPUBKEYNOTMATCH.
            #expect(result.exitCode == 90)
        }
    }

    /// The version header goes on every response, because the client compares
    /// it on every response.
    @Test("every response carries the protocol version")
    func protocolHeaderPresent() async throws {
        try await withServer(handler: EchoHandler()) { port, identity in
            let response = try Curl.get("https://127.0.0.1:\(port)/v1/models", pin: identity.spkiPin)

            #expect(response.header("x-localis-protocol") == "1")
        }
    }

    /// **SSE frames must reach the client as they are produced.**
    ///
    /// Timed rather than merely collected: a server that buffers the whole
    /// stream delivers identical bytes, so any test that reads to the end and
    /// then asserts on the content passes either way. What distinguishes them
    /// is *when* the first frame lands.
    ///
    /// The handler here waits between frames. If the response were buffered,
    /// the first line could not appear before the last one was produced.
    @Test("streamed frames arrive before the stream ends")
    func streamingIsIncremental() async throws {
        try await withServer(handler: SlowStreamHandler()) { port, identity in
            let started = Date()
            let firstLineAt = try Curl.timeToFirstLine(
                "https://127.0.0.1:\(port)/v1/chat/completions",
                pin: identity.spkiPin,
                method: "POST"
            )
            let total = Date().timeIntervalSince(started)

            // The handler emits three frames 400ms apart, so a buffered
            // response cannot produce a line before ~1.2s.
            #expect(firstLineAt < 0.8, "first frame took \(firstLineAt)s — response appears buffered")
            #expect(total > 0.8, "stream finished too fast; the handler may not have run")
        }
    }

    /// TLS 1.2 must be refused.
    ///
    /// The only client is a current iOS build, so there is no legacy peer to
    /// accommodate — and the reason to state this as a test rather than as a
    /// line of configuration is that lowering the floor changes nothing
    /// observable. Every other test in this suite passes identically against a
    /// server that accepts TLS 1.0.
    @Test("a TLS 1.2 client is refused")
    func tls12Refused() async throws {
        try await withServer(handler: EchoHandler()) { port, identity in
            let result = Curl.raw([
                "--max-time", "5",
                "--insecure",
                "--tls-max", "1.2",
                "--pinnedpubkey", "sha256//\(identity.spkiPin)",
                "https://127.0.0.1:\(port)/v1/models",
            ])

            #expect(result.exitCode != 0, "a TLS 1.2 client connected")
        }
    }

    /// The turn id has to be readable off the response head, before any event.
    /// A client that learns it only at the end cannot resume a turn that was
    /// interrupted — which is the only situation resume exists for.
    @Test("the turn id is on the response head, not in the body")
    func turnIDOnHead() async throws {
        try await withServer(handler: SlowStreamHandler()) { port, identity in
            let response = try Curl.get(
                "https://127.0.0.1:\(port)/v1/chat/completions",
                pin: identity.spkiPin,
                method: "POST"
            )

            #expect(response.header("x-localis-turn-id") == SlowStreamHandler.turnID)
        }
    }

    /// An oversized body is refused with a status, not by dropping the
    /// connection — a dropped connection reads as a network fault and invites
    /// the client to retry the same request forever.
    @Test("an oversized body is refused with a status")
    func oversizedBodyRefused() async throws {
        try await withServer(handler: EchoHandler()) { port, identity in
            let payload = String(repeating: "x", count: 9 * 1024 * 1024)
            let response = try Curl.post(
                "https://127.0.0.1:\(port)/v1/chat/completions",
                pin: identity.spkiPin,
                body: payload
            )

            #expect(response.status == 413)
        }
    }

    // MARK: - Harness

    /// Starts a server on a free port, runs `body`, and always shuts it down.
    ///
    /// Port 0 rather than a fixed number: a hard-coded port makes the suite
    /// fail when anything else on the machine happens to hold it, which reads
    /// as a bug in the bridge.
    private func withServer(
        handler: any BridgeHandling,
        _ body: (Int, BridgeIdentity) throws -> Void
    ) async throws {
        let identity = try BridgeIdentity.generate()
        let server = BridgeServer(identity: identity, handler: handler)
        let port = try await server.start(host: "127.0.0.1", port: 0)

        defer { Task { try? await server.stop() } }

        try body(port, identity)
    }
}

// MARK: - Handlers

private struct EchoHandler: BridgeHandling {
    func respond(to request: BridgeRequest) async -> BridgeResponse {
        .json(status: 200, object: ["models": [String](), "path": request.uri])
    }
}

/// Emits three frames with a gap between them, so buffering is observable.
private struct SlowStreamHandler: BridgeHandling {
    static let turnID = "t-slow-stream"

    func respond(to request: BridgeRequest) async -> BridgeResponse {
        .stream(
            status: 200,
            headers: ["x-localis-turn-id": Self.turnID],
            events: AsyncThrowingStream { continuation in
                Task {
                    for index in 0..<3 {
                        continuation.yield([UInt8]("data: {\"seq\":\(index)}\n\n".utf8))
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    continuation.yield([UInt8]("data: [DONE]\n\n".utf8))
                    continuation.finish()
                }
            }
        )
    }
}

// MARK: - curl

/// The external HTTP client these tests are written against.
private enum Curl {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: String

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    struct Result {
        let exitCode: Int32
        let stdout: String
    }

    static func get(_ url: String, pin: String, method: String = "GET") throws -> Response {
        let result = raw([
            "--max-time", "20",
            "--include",
            // `--insecure` disables *CA* validation, which is right: the
            // certificate is self-signed and no CA vouches for it. Trust comes
            // from `--pinnedpubkey`, which is exactly what the phone does.
            "--insecure",
            "--pinnedpubkey", "sha256//\(pin)",
            "--request", method,
            url,
        ])

        return try parse(result)
    }

    static func post(_ url: String, pin: String, body: String) throws -> Response {
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("curl-body-\(UUID().uuidString)")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let result = raw([
            "--max-time", "20",
            "--include",
            "--insecure",
            "--pinnedpubkey", "sha256//\(pin)",
            "--data-binary", "@\(bodyFile.path)",
            url,
        ])

        return try parse(result)
    }

    /// Seconds until curl writes its first body line.
    ///
    /// Measured by reading curl's stdout as it streams, rather than by waiting
    /// for it to exit — which is the whole distinction being tested.
    static func timeToFirstLine(_ url: String, pin: String, method: String) throws -> TimeInterval {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--max-time", "20",
            "--no-buffer",
            "--silent",
            "--insecure",
            "--pinnedpubkey", "sha256//\(pin)",
            "--request", method,
            url,
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let started = Date()
        try process.run()

        // Blocking read of the first chunk. `availableData` returns as soon as
        // anything is written, which is the moment being measured.
        let first = stdout.fileHandleForReading.availableData
        let elapsed = Date().timeIntervalSince(started)

        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard !first.isEmpty else {
            throw Failure.noOutput
        }
        return elapsed
    }

    static func raw(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error"] + arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: data, as: UTF8.self)
        )
    }

    private static func parse(_ result: Result) throws -> Response {
        guard result.exitCode == 0 else {
            throw Failure.curlFailed(code: result.exitCode)
        }

        let parts = result.stdout.components(separatedBy: "\r\n\r\n")
        let headBlock = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")

        var lines = headBlock.components(separatedBy: "\r\n")
        let statusLine = lines.isEmpty ? "" : lines.removeFirst()
        let status = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return Response(status: status, headers: headers, body: body)
    }

    enum Failure: Error {
        case curlFailed(code: Int32)
        case noOutput
    }
}
