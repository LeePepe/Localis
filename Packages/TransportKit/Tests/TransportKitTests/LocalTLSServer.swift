import Foundation
import LocalisModels
import Network
import Security

@testable import TransportKit

/// A TLS server on localhost, with a self-signed certificate generated per run
/// (#37).
///
/// **Why this exists.** Pinning has three ways to fail and only one of them is
/// visible to a test that never opens a socket: `SPKIPinning.verify` returning
/// the wrong verdict. The other two — the system's default policy rejecting the
/// certificate before our delegate is consulted, and the delegate never being
/// invoked at all — require a real handshake to observe, and both were real
/// (#31, #32). `LiveBridgeIntegrationTests` reaches them but needs a bridge on
/// another machine, so it never runs in CI; this harness reaches them with
/// nothing but the machine running the tests.
///
/// ## Two dead ends, recorded because both look like a mistake in the caller
///
/// **PKCS#12 is not usable here.** The obvious route — `openssl pkcs12 -export`
/// then `SecPKCS12Import` — cannot work on a stock Mac. `/usr/bin/openssl` is
/// LibreSSL 3.3.6, and the p12 it produces uses an encryption Security.framework
/// will not open: `SecPKCS12Import` *succeeds*, hands back an identity, and the
/// process then dies with `NSInvalidArgumentException:
/// SecKeyCopyExternalRepresentation called with NULL SecKeyRef` when the private
/// key is touched. OpenSSL's `-legacy` flag exists for exactly this, and is one
/// LibreSSL does not recognise — and LibreSSL answers an unknown flag by
/// printing usage and **exiting 0 without producing the output file**, so a
/// script that checks the exit code reads it as success. Hence: key and
/// certificate are imported separately and combined with `SecIdentityCreate`.
///
/// **The key is RSA, and that is not a strength preference.**
/// `SecKeyCreateWithData` wants an EC private key as the bare X9.63
/// `04||X||Y||K`; `openssl ec -outform DER` emits the SEC1/RFC 5915 structure
/// around it, and the import fails with `-50 "EC private key creation from data
/// failed"`. RSA has no such mismatch — `openssl rsa -outform DER` emits
/// PKCS#1, which is what Security.framework expects. RSA-2048 is also one of the
/// key shapes `SPKIPinning.spkiHeader` knows a DER prefix for, so the pin this
/// harness computes is the same value the production code computes.
enum LocalTLSServer {
    /// Everything a test needs to talk to one running server.
    struct Running {
        /// The port the listener actually bound. Never a fixed number: a fixed
        /// port turns "another process has it" into a failure of whatever the
        /// test was really checking.
        let port: UInt16
        /// The pin for this server's certificate, computed the same way the
        /// production code computes it — via `SPKIPinning.spkiHash`, not by a
        /// second implementation that could agree with itself while both are
        /// wrong.
        let pin: SPKIHash
        /// Keeps the listener alive; cancelled on deinit.
        private let handle: Handle

        init(port: UInt16, pin: SPKIHash, handle: Handle) {
            self.port = port
            self.pin = pin
            self.handle = handle
        }

        var url: URL { URL(string: "https://localhost:\(port)/")! }

        final class Handle {
            private let listener: NWListener
            private let connections: Locked<[NWConnection]>

            init(listener: NWListener, connections: Locked<[NWConnection]>) {
                self.listener = listener
                self.connections = connections
            }

            deinit {
                listener.cancel()
                connections.get().forEach { $0.cancel() }
            }
        }
    }

    /// A failure to *set up* the server, which is not a failure of what is
    /// being tested. Named cases rather than a single message so a test that
    /// cannot start a server says which step refused.
    enum SetupFailure: Error, CustomStringConvertible {
        case opensslFailed(step: String, status: Int32, stderr: String)
        case missingOutput(String)
        case securityAPIFailed(String, OSStatus)
        case identityUnavailable(String)
        case pinUnavailable
        case listenerFailed

        var description: String {
            switch self {
            case let .opensslFailed(step, status, stderr):
                return "openssl \(step) exited \(status): \(stderr)"
            case let .missingOutput(path):
                // LibreSSL exits 0 on an unknown flag, so a missing file is a
                // distinct and more likely failure than a non-zero exit.
                return "openssl produced no file at \(path) (it exits 0 on flags it does not know)"
            case let .securityAPIFailed(api, status):
                return "\(api) failed with OSStatus \(status)"
            case let .identityUnavailable(reason):
                return "could not build a SecIdentity: \(reason)"
            case .pinUnavailable:
                return "SPKIPinning.spkiHash could not read the generated certificate"
            case .listenerFailed:
                return "NWListener never reached .ready"
            }
        }
    }

    // MARK: - Starting one

    /// Generates a fresh certificate and starts a TLS listener on an
    /// OS-assigned port.
    ///
    /// - Parameter respondWith: the raw HTTP response written to every
    ///   connection once the handshake completes. Raw bytes rather than a
    ///   status code because the point is the handshake, and a test that needs
    ///   a specific body should say exactly what it wants on the wire.
    static func start(
        respondWith response: String = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    ) throws -> Running {
        let (identity, certificate) = try makeIdentity()

        guard let pin = SPKIPinning.spkiHash(of: certificate) else {
            throw SetupFailure.pinUnavailable
        }

        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw SetupFailure.identityUnavailable("sec_identity_create returned nil")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)

        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)
        let connections = Locked<[NWConnection]>([])

        listener.newConnectionHandler = { connection in
            // Held so ARC does not release the connection mid-handshake; a
            // released NWConnection closes, which the client sees as a
            // transport error rather than as anything about the certificate.
            connections.mutate { $0.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
            }
            connection.start(queue: .global())
        }

        let port = try awaitReady(listener)
        return Running(
            port: port,
            pin: pin,
            handle: Running.Handle(listener: listener, connections: connections)
        )
    }

    /// Blocks until the listener is ready, or gives up.
    ///
    /// Semaphore rather than a continuation because `start(...)` is
    /// synchronous: a test that has to `await` its fixture setup reads as
    /// though the setup is part of what is being measured.
    private static func awaitReady(_ listener: NWListener) throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        let bound = Locked<UInt16?>(nil)
        let fired = Locked<Bool>(false)

        listener.stateUpdateHandler = { state in
            let alreadyFired = fired.mutate { was -> Bool in
                defer { was = true }
                return was
            }
            guard !alreadyFired else { return }

            switch state {
            case .ready:
                bound.set(listener.port?.rawValue)
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                // Not fired after all — reset so a later .ready still counts.
                fired.set(false)
            }
        }
        listener.start(queue: .global())

        guard ready.wait(timeout: .now() + 10) == .success, let port = bound.get() else {
            listener.cancel()
            throw SetupFailure.listenerFailed
        }
        return port
    }

    // MARK: - Certificate and identity

    /// openssl for the certificate, Security.framework for the key, then
    /// `SecIdentityCreate` to join them. See the type comment for why not p12.
    private static func makeIdentity() throws -> (SecIdentity, SecCertificate) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyPEM = directory.appendingPathComponent("key.pem").path
        let certPEM = directory.appendingPathComponent("cert.pem").path
        let keyDER = directory.appendingPathComponent("key.der").path
        let certDER = directory.appendingPathComponent("cert.der").path

        try openssl(
            step: "req",
            ["req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPEM, "-out", certPEM,
             "-days", "1", "-nodes", "-subj", "/CN=localhost"],
            produces: [keyPEM, certPEM]
        )
        try openssl(step: "rsa", ["rsa", "-in", keyPEM, "-outform", "DER", "-out", keyDER],
                    produces: [keyDER])
        try openssl(step: "x509", ["x509", "-in", certPEM, "-outform", "DER", "-out", certDER],
                    produces: [certDER])

        let certificateData = try Data(contentsOf: URL(fileURLWithPath: certDER))
        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyDER))

        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw SetupFailure.identityUnavailable("SecCertificateCreateWithData returned nil")
        }

        var keyError: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &keyError) else {
            let detail = keyError.map { "\($0.takeRetainedValue())" } ?? "no error returned"
            throw SetupFailure.identityUnavailable("SecKeyCreateWithData: \(detail)")
        }

        return (try makeIdentity(certificate: certificate, key: key), certificate)
    }

    /// Joins a certificate and its private key into a `SecIdentity`.
    ///
    /// `SecIdentityCreate` is resolved with `dlsym` rather than called directly:
    /// it is exported by Security.framework but not declared in the public
    /// headers, so a direct call does not compile. The alternative is a keychain
    /// round-trip, which writes to the developer's login keychain — a test that
    /// leaves state on the machine running it, and on CI needs an unlocked
    /// keychain it does not have.
    private static func makeIdentity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity {
        typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "SecIdentityCreate") else {
            throw SetupFailure.identityUnavailable("SecIdentityCreate is not exported on this OS")
        }
        let create = unsafeBitCast(symbol, to: Create.self)
        guard let identity = create(nil, certificate, key)?.takeRetainedValue() else {
            throw SetupFailure.identityUnavailable("SecIdentityCreate returned nil")
        }
        return identity
    }

    /// Runs `/usr/bin/env openssl` and insists the output files exist.
    ///
    /// The file check is the load-bearing half. LibreSSL answers an unrecognised
    /// flag by printing usage and exiting 0, so a non-zero exit is the *less*
    /// likely way this fails and the exit code alone would let a silent no-op
    /// through to a confusing failure several steps later.
    private static func openssl(step: String, _ arguments: [String], produces: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["openssl"] + arguments
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SetupFailure.opensslFailed(
                step: step,
                status: process.terminationStatus,
                stderr: String(data: errorData, encoding: .utf8) ?? ""
            )
        }
        for path in produces where !FileManager.default.fileExists(atPath: path) {
            throw SetupFailure.missingOutput(path)
        }
    }
}

/// A value behind a lock, so it can be mutated from the `@Sendable` callbacks
/// `Network` and `URLSession` deliver on arbitrary queues.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
