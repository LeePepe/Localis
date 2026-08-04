import Crypto
import Foundation
import X509

/// The SPKI pin: SHA-256 of a certificate's SubjectPublicKeyInfo, base64.
///
/// **This value must equal, byte for byte, what the iOS client computes for the
/// same certificate** (`TransportKit.SPKIPinning.spkiHash`). It is the whole
/// basis of trust between phone and Mac: the certificate is self-signed, so no
/// CA vouches for it, and this hash is the only thing that distinguishes this
/// bridge from anything else answering on the same address.
///
/// The two implementations share no code and cannot — one runs on iOS against
/// Security.framework, one runs here against swift-certificates. They agree
/// only if they construct the same bytes from the same reasoning. That is why
/// the tests check against `openssl` rather than against each other: an
/// independent third party breaks the tie, and is also what a human operator
/// would use to read the value off the certificate by eye.
///
/// **Why the header has to be prepended.** Both libraries hand back the *bare*
/// public key — the elliptic curve point, or the PKCS#1 RSA structure — not the
/// SubjectPublicKeyInfo that wraps it. `subjectPublicKeyInfoBytes` is named for
/// the structure it came from, not for what it returns. Hashing that bare key
/// would produce a stable, self-consistent, and wrong answer: stable enough to
/// pass any test that only compares this code to itself.
public enum SPKIPin {
    /// The pin for `certificate`, or nil if its key type is one we cannot
    /// describe in DER.
    ///
    /// Returning nil rather than a best-effort hash is deliberate. A pin
    /// computed from a header we guessed at would be a pin the client never
    /// matches — a connection that fails at TLS with no explanation. Better to
    /// refuse to generate such a certificate at all.
    public static func pin(for certificate: Certificate) -> String? {
        pin(for: certificate.publicKey)
    }

    /// The pin for a public key on its own.
    public static func pin(for key: Certificate.PublicKey) -> String? {
        guard let header = algorithmIdentifierPrefix(for: key) else { return nil }

        var spki = header
        spki.append(contentsOf: key.subjectPublicKeyInfoBytes)

        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// The DER prefix that turns a bare public key into a SubjectPublicKeyInfo.
    ///
    /// These byte strings are copied from the iOS side deliberately rather than
    /// derived here. They encode the ASN.1 SEQUENCE header, the algorithm OID,
    /// and the BIT STRING wrapper for exactly one key type and length each —
    /// there is nothing to compute, and a divergence between the two lists is
    /// precisely the failure this pairing is exposed to.
    ///
    /// An unrecognised key returns nil and the caller fails closed. The list is
    /// short on purpose: the bridge generates its own key, so the only entry
    /// that must be right today is P-256.
    private static func algorithmIdentifierPrefix(for key: Certificate.PublicKey) -> [UInt8]? {
        if P256.Signing.PublicKey(key) != nil {
            return [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
                0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01,
                0x07, 0x03, 0x42, 0x00,
            ]
        }
        if P384.Signing.PublicKey(key) != nil {
            return [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
                0x02, 0x01, 0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62,
                0x00,
            ]
        }
        // RSA and Ed25519 are reachable only if someone supplies a certificate
        // we did not generate. They are absent rather than approximated: the
        // RSA prefix depends on the modulus size, and Ed25519 is not in the
        // iOS list at all, so accepting one here would produce a pin the client
        // can never match.
        return nil
    }
}
