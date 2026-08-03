import CryptoKit
import Foundation
import LocalisModels
import Security

/// Certificate pinning for one host (constitution V, FR-028).
///
/// The bridge's certificate is self-signed, so the system trust store has
/// nothing to say about it. What replaces CA validation is a hash of the public
/// key recorded at pairing: from then on, the connection is allowed only if the
/// certificate presents the same key.
///
/// **What is hashed is the SubjectPublicKeyInfo, not the certificate.** Pinning
/// the whole certificate breaks on every renewal even when the key never
/// changed, which teaches the user that "re-pair" is routine — and a habit of
/// re-pairing on demand is precisely what makes a real key substitution look
/// unremarkable.
///
/// **There is no bypass.** No parameter, no flag, no "trust anyway" path — the
/// outcomes are match, mismatch, and unreadable, and only the first connects
/// (spec US1 scenario 7). A prompt offering to continue past a mismatch is not
/// a worse UX for this feature; it is the removal of the feature, since an
/// attacker's certificate arrives looking exactly like a legitimate reinstall.
public enum SPKIPinning {
    /// Result of comparing a presented certificate against a host's pin.
    ///
    /// Three cases, of which exactly one connects. Adding a fourth that
    /// connects would be the bypass this type exists to make inexpressible.
    public enum Outcome: Hashable, Sendable {
        /// The key matches the pin recorded at pairing.
        case matched
        /// A different key. The user must pair again; there is no override.
        case mismatched
        /// The certificate could not be read well enough to compare.
        ///
        /// Refused like a mismatch: a certificate we cannot parse is one we
        /// cannot verify, and "unparseable" is a state an attacker can arrange.
        case unusableCertificate

        public var allowsConnection: Bool {
            self == .matched
        }
    }

    /// Compares `certificate` against `pin`.
    public static func verify(certificate: SecCertificate, against pin: SPKIHash) -> Outcome {
        guard let presented = spkiHash(of: certificate) else { return .unusableCertificate }
        return presented == pin ? .matched : .mismatched
    }

    /// SHA-256 of the certificate's SubjectPublicKeyInfo, base64 encoded.
    ///
    /// Returns nil when the key cannot be extracted — an unreadable certificate
    /// is refused by the caller rather than given the benefit of the doubt.
    public static func spkiHash(of certificate: SecCertificate) -> SPKIHash? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }

        // `SecKeyCopyExternalRepresentation` returns the bare key, without the
        // algorithm identifier that makes it an SPKI. The header is prepended
        // so this hash equals what `openssl x509 -pubkey | openssl dgst` gives
        // — the value an operator can compute on the Mac to compare by eye.
        guard let header = spkiHeader(for: attributes) else { return nil }

        return SPKIHash(base64: sha256Base64(of: header + keyData))
    }

    /// Base64 SHA-256 of arbitrary bytes. Exposed for tests that need to assert
    /// what is *not* being hashed.
    static func sha256Base64(of data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    /// The DER AlgorithmIdentifier prefix for a key, by type and size.
    ///
    /// These are fixed byte strings from the relevant RFCs, not something to
    /// compute: each encodes the ASN.1 SEQUENCE header, the algorithm OID, and
    /// the BIT STRING wrapper for one key type and length.
    ///
    /// An unrecognised combination returns nil, and the connection is refused —
    /// failing closed on a key type we cannot describe is the only safe answer.
    private static func spkiHeader(for attributes: [CFString: Any]) -> Data? {
        guard let type = attributes[kSecAttrKeyType] as? String,
              let bits = attributes[kSecAttrKeySizeInBits] as? Int else {
            return nil
        }

        let isRSA = type == (kSecAttrKeyTypeRSA as String)
        let isEC = type == (kSecAttrKeyTypeECSECPrimeRandom as String)

        switch (isRSA, isEC, bits) {
        case (true, _, 2048):
            return Data([
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48,
                0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01,
                0x0F, 0x00,
            ])
        case (true, _, 4096):
            return Data([
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48,
                0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02,
                0x0F, 0x00,
            ])
        case (_, true, 256):
            return Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
                0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01,
                0x07, 0x03, 0x42, 0x00,
            ])
        case (_, true, 384):
            return Data([
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
                0x02, 0x01, 0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62,
                0x00,
            ])
        default:
            return nil
        }
    }
}
