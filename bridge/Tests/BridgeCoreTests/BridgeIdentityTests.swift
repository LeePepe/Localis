import Foundation
import Testing

@testable import BridgeCore

/// The self-signed identity this bridge presents, and the pin the iOS client
/// will record for it.
///
/// **This suite is the reason the bridge is written in Swift.** The pin is a
/// hash the two sides must compute to the same byte string, and the iOS side
/// derives it from a hand-written DER AlgorithmIdentifier prefix. If these
/// agree only because both sides share my misunderstanding, they agree in the
/// test and disagree on the wire.
///
/// So the assertions here are anchored to something outside both
/// implementations: `openssl`, which is what an operator would use to read the
/// same value off the certificate by eye.
@Suite("BridgeIdentity — self-signed certificate and SPKI pin", .serialized)
struct BridgeIdentityTests {
    /// A certificate must be usable for TLS at all: parseable, and holding the
    /// key we think it holds.
    @Test("the generated certificate is a parseable X.509 with a P-256 key")
    func certificateIsParseable() throws {
        let identity = try BridgeIdentity.generate()
        let openssl = try OpenSSL.text(ofCertificate: identity.certificatePEM)

        #expect(openssl.contains("id-ecPublicKey"))
        #expect(openssl.contains("prime256v1"))
    }

    /// **The load-bearing assertion.** `openssl x509 -pubkey | openssl dgst
    /// -sha256 -binary | base64` is exactly the pipeline the iOS pinning code
    /// documents itself as matching. If my hash and openssl's agree, then my
    /// hash and the iOS client's agree — without either side having to trust
    /// the other's ASN.1 reasoning.
    @Test("the pin equals what openssl computes from the certificate")
    func pinMatchesOpenSSL() throws {
        let identity = try BridgeIdentity.generate()

        #expect(identity.spkiPin == (try OpenSSL.spkiPin(ofCertificate: identity.certificatePEM)))
    }

    /// The pin must hash the SubjectPublicKeyInfo, not the certificate.
    /// Hashing the whole certificate would break on every renewal even when the
    /// key never changed — teaching the user that re-pairing is routine, which
    /// is what makes a real key substitution look unremarkable.
    @Test("the pin is not a hash of the whole certificate")
    func pinIsNotCertificateHash() throws {
        let identity = try BridgeIdentity.generate()
        let certificateDigest = try OpenSSL.sha256Base64OfDER(identity.certificatePEM)

        #expect(identity.spkiPin != certificateDigest)
    }

    /// Two bridges must not share a key. A fixed or seeded key would make one
    /// machine's pin accept another's certificate, which is the property
    /// pinning exists to deny.
    @Test("each identity has its own key")
    func identitiesAreDistinct() throws {
        let first = try BridgeIdentity.generate()
        let second = try BridgeIdentity.generate()

        #expect(first.spkiPin != second.spkiPin)
    }

    /// The pin's shape is what gets typed and compared by a human during
    /// pairing, and what the client stores. Base64 of SHA-256 is 44 characters
    /// ending in `=`.
    @Test("the pin is base64 of a SHA-256 digest")
    func pinShape() throws {
        let pin = try BridgeIdentity.generate().spkiPin

        #expect(pin.count == 44)
        #expect(Data(base64Encoded: pin)?.count == 32)
    }

    /// A certificate whose validity has already ended, or has not begun, fails
    /// TLS on the client with an error that looks like a network fault. The
    /// window is checked here rather than discovered in the field.
    @Test("the certificate is valid now and for a usable period")
    func validityWindow() throws {
        let identity = try BridgeIdentity.generate()
        let (notBefore, notAfter) = try OpenSSL.validity(ofCertificate: identity.certificatePEM)

        let now = Date()
        #expect(notBefore <= now)
        // Comfortably beyond any plausible session, so a long-lived pairing
        // does not silently expire mid-conversation.
        #expect(notAfter > now.addingTimeInterval(365 * 24 * 3600))
    }

    /// The private key must never be written where another user can read it.
    /// A bridge key readable by any account on the machine is a key that can
    /// impersonate this bridge to an already-paired phone.
    @Test("a persisted key is written owner-readable only")
    func persistedKeyIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try BridgeIdentity.loadOrCreate(in: directory)

        let keyURL = directory.appendingPathComponent("key.pem")
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)

        #expect(permissions & 0o077 == 0)
    }

    /// Regenerating on every launch would invalidate every existing pairing —
    /// each restart would look to a paired phone exactly like a key
    /// substitution attack.
    @Test("a persisted identity is reused across loads")
    func persistedIdentityIsStable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try BridgeIdentity.loadOrCreate(in: directory)
        let second = try BridgeIdentity.loadOrCreate(in: directory)

        #expect(first.spkiPin == second.spkiPin)
    }
}

// MARK: - Independent verification

/// Shells out to `openssl` so the assertions have a witness outside this
/// codebase.
///
/// Using the system tool rather than a second Swift implementation is the
/// point: two implementations written by the same author from the same reading
/// of the spec make the same mistake.
private enum OpenSSL {
    static func text(ofCertificate pem: String) throws -> String {
        try run(["x509", "-noout", "-text"], input: pem)
    }

    /// `openssl x509 -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256 | base64`
    ///
    /// This is the pipeline `SPKIPinning` names in its own doc comment as the
    /// value it must equal.
    static func spkiPin(ofCertificate pem: String) throws -> String {
        let publicKeyPEM = try run(["x509", "-noout", "-pubkey"], input: pem)
        let der = try runBinary(["pkey", "-pubin", "-outform", "DER"], input: publicKeyPEM)

        return try sha256Base64(of: der)
    }

    static func sha256Base64OfDER(_ pem: String) throws -> String {
        let der = try runBinary(["x509", "-outform", "DER"], input: pem)
        return try sha256Base64(of: der)
    }

    /// Digest computed by openssl rather than by the same crypto library the
    /// implementation uses, so a shared misuse of that library cannot make both
    /// sides wrong in the same direction.
    private static func sha256Base64(of data: Data) throws -> String {
        try runBinary(["dgst", "-sha256", "-binary"], inputData: data).base64EncodedString()
    }

    static func validity(ofCertificate pem: String) throws -> (Date, Date) {
        let output = try run(["x509", "-noout", "-dates"], input: pem)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        func date(labelled label: String) throws -> Date {
            let line = try #require(
                output.split(separator: "\n").first { $0.hasPrefix(label) },
                "openssl did not report \(label)"
            )
            let text = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            return try #require(formatter.date(from: text), "unparseable date: \(text)")
        }

        return (try date(labelled: "notBefore="), try date(labelled: "notAfter="))
    }

    // MARK: Process plumbing

    private static func run(_ arguments: [String], input: String) throws -> String {
        String(decoding: try runBinary(arguments, input: input), as: UTF8.self)
    }

    private static func runBinary(_ arguments: [String], input: String) throws -> Data {
        try runBinary(arguments, inputData: Data(input.utf8))
    }

    private static func runBinary(_ arguments: [String], inputData: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(inputData)
        try stdin.fileHandleForWriting.close()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OpenSSLFailure(
                message: "openssl \(arguments.joined(separator: " ")): "
                    + String(decoding: errors, as: UTF8.self)
            )
        }
        return output
    }

    struct OpenSSLFailure: Error {
        let message: String
    }
}
