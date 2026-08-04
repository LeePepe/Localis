import Crypto
import Foundation
import SwiftASN1
import X509

/// The bridge's TLS identity: a self-signed certificate, its private key, and
/// the pin the phone records at pairing.
///
/// **Self-signed by necessity.** The bridge answers on a LAN address that no CA
/// will issue for, so there is nothing to validate against the system trust
/// store. What replaces CA validation is the SPKI pin (see ``SPKIPin``), which
/// the phone learns out of band during pairing and enforces on every subsequent
/// connection. This is the whole of constitution §V on this side: TLS always,
/// and no path that connects without it.
///
/// **The key is generated on this Mac and never leaves it.** Not shipped, not
/// derived from anything guessable, not shared between installs — a bridge whose
/// key another machine could reproduce is a bridge any machine could
/// impersonate to an already-paired phone.
public struct BridgeIdentity: Sendable {
    /// PEM-encoded certificate, ready for NIOSSL and for an operator to inspect
    /// with `openssl x509`.
    public let certificatePEM: String

    /// PEM-encoded private key. Never logged, never sent, and written only with
    /// owner-only permissions (constitution §I).
    public let privateKeyPEM: String

    /// The value the phone stores and compares on every connection.
    public let spkiPin: String

    public let certificate: Certificate

    /// Ten years. The certificate protects nothing on its own — the pin does
    /// that — so a short lifetime buys no security, while an expiry mid-use
    /// costs the user a re-pair that looks exactly like a key substitution.
    private static let validity: TimeInterval = 10 * 365 * 24 * 3600

    /// Backdated so a phone whose clock runs slightly behind this Mac does not
    /// see a not-yet-valid certificate. Clock skew between two consumer devices
    /// is ordinary; a TLS failure that resolves itself an hour later is not
    /// something a user can diagnose.
    private static let backdate: TimeInterval = 3600

    /// Creates a fresh identity. Each call produces a distinct key.
    public static func generate(commonName: String = "Localis Bridge") throws -> BridgeIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let certificateKey = Certificate.PrivateKey(privateKey)
        let publicKey = Certificate.PublicKey(privateKey.publicKey)

        let name = try DistinguishedName {
            CommonName(commonName)
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-backdate),
            notValidAfter: now.addingTimeInterval(validity),
            // Self-signed: issuer and subject are the same name, and the key
            // that signs is the key being certified.
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true))
                try ExtendedKeyUsage([.serverAuth])
                // The phone connects by IP or by the Bonjour hostname, neither
                // of which is known when this is generated. The SAN is filled
                // with what a self-signed LAN certificate can honestly claim;
                // hostname matching is not what establishes trust here — the
                // pin is.
                SubjectAlternativeNames([
                    .dnsName("localhost"),
                    .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
                ])
            },
            issuerPrivateKey: certificateKey
        )

        guard let pin = SPKIPin.pin(for: certificate) else {
            // Unreachable with a P-256 key, but stated rather than assumed: a
            // certificate whose pin cannot be computed is one no phone can ever
            // connect to, and failing here is far cheaper than failing at TLS.
            throw Failure.unpinnableKey
        }

        return BridgeIdentity(
            certificatePEM: try certificate.serializeAsPEM().pemString,
            privateKeyPEM: try certificateKey.serializeAsPEM().pemString,
            spkiPin: pin,
            certificate: certificate
        )
    }

    /// Loads the identity stored in `directory`, generating and persisting one
    /// if it is not there.
    ///
    /// **Stability matters more than freshness here.** Regenerating on each
    /// launch would present every paired phone with a new key on every restart
    /// — which is indistinguishable, to the phone, from an attacker
    /// substituting its own. The pin only means something if it outlives the
    /// process.
    public static func loadOrCreate(
        in directory: URL,
        commonName: String = "Localis Bridge"
    ) throws -> BridgeIdentity {
        let certificateURL = directory.appendingPathComponent("cert.pem")
        let keyURL = directory.appendingPathComponent("key.pem")

        if let existing = try load(certificateURL: certificateURL, keyURL: keyURL) {
            return existing
        }

        let identity = try generate(commonName: commonName)
        try persist(identity, certificateURL: certificateURL, keyURL: keyURL, in: directory)
        return identity
    }

    /// Reads a stored identity, or nil if none is stored.
    ///
    /// A file that exists but does not parse is a hard error rather than a
    /// silent regeneration: overwriting it would revoke every existing pairing
    /// without anyone having asked, and the user would see only that their
    /// phone stopped connecting.
    private static func load(certificateURL: URL, keyURL: URL) throws -> BridgeIdentity? {
        guard FileManager.default.fileExists(atPath: certificateURL.path),
              FileManager.default.fileExists(atPath: keyURL.path) else {
            return nil
        }

        let certificatePEM = try String(contentsOf: certificateURL, encoding: .utf8)
        let privateKeyPEM = try String(contentsOf: keyURL, encoding: .utf8)

        let certificate: Certificate
        do {
            certificate = try Certificate(pemEncoded: certificatePEM)
        } catch {
            throw Failure.unreadableStoredIdentity(path: certificateURL.path)
        }

        guard let pin = SPKIPin.pin(for: certificate) else {
            throw Failure.unpinnableKey
        }

        return BridgeIdentity(
            certificatePEM: certificatePEM,
            privateKeyPEM: privateKeyPEM,
            spkiPin: pin,
            certificate: certificate
        )
    }

    private static func persist(
        _ identity: BridgeIdentity,
        certificateURL: URL,
        keyURL: URL,
        in directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        try identity.certificatePEM.write(to: certificateURL, atomically: true, encoding: .utf8)

        // The key is written through `FileManager` with its mode set in the
        // same call, rather than written first and chmod'd after. A key that is
        // world-readable for even a moment is a key that was world-readable.
        guard FileManager.default.createFile(
            atPath: keyURL.path,
            contents: Data(identity.privateKeyPEM.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw Failure.cannotWriteKey(path: keyURL.path)
        }
    }

    public enum Failure: Error, Equatable {
        /// The key type has no DER prefix we can describe, so no pin can be
        /// computed and no phone could ever verify it.
        case unpinnableKey
        /// A stored certificate exists but cannot be parsed. Reported rather
        /// than replaced — see ``load(certificateURL:keyURL:)``.
        case unreadableStoredIdentity(path: String)
        case cannotWriteKey(path: String)
    }
}
