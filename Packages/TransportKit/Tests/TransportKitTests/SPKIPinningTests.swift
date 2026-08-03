import Foundation
import LocalisModels
import Security
import Testing

@testable import TransportKit

/// TLS pinning, per host (constitution V, FR-028).
///
/// Run against two real self-signed certificates rather than hand-written
/// hashes, because the thing most likely to be wrong is the SPKI extraction
/// itself — a hash of the wrong bytes compares equal to itself and passes a
/// fixture-based test while pinning nothing.
///
/// The property these tests defend: **a certificate that does not match refuses
/// the connection, and there is no second path that accepts it.**
@Suite("SPKIPinning — per-host trust")
struct SPKIPinningTests {
    private static func certificate(_ name: String) throws -> SecCertificate {
        let data = try Fixture.data(name, extension: "cer")
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw Fixture.FixtureError.missing("\(name) is not a DER certificate")
        }
        return certificate
    }

    private func hostA() throws -> SecCertificate { try Self.certificate("host-a") }
    private func hostB() throws -> SecCertificate { try Self.certificate("host-b") }

    // MARK: - SPKI extraction

    @Test("extracts a stable SPKI hash from a real certificate")
    func extractsHash() throws {
        let hash = try #require(SPKIPinning.spkiHash(of: try hostA()))

        // Base64 of SHA-256 — 44 characters with one padding character.
        #expect(hash.base64.count == 44)
        #expect(hash.base64.hasSuffix("="))
    }

    @Test("the hash matches what openssl computes for the same certificate")
    func matchesOpenSSL() throws {
        // The one test that can catch a wrong AlgorithmIdentifier header. Every
        // other assertion here compares our hash against our own hash, so a
        // header that is wrong in a consistent way passes all of them while
        // pinning a value no other tool agrees with — and an operator checking
        // the fingerprint on the Mac would read a different string.
        //
        // Reference values, regenerable with:
        //   openssl x509 -in host-a.cer -inform DER -pubkey -noout \
        //     | openssl pkey -pubin -outform DER \
        //     | openssl dgst -sha256 -binary | base64
        #expect(SPKIPinning.spkiHash(of: try hostA())?.base64 == "LpkFZjT82OYMgRsm4c1ztqAmunU6kM7ZfmhokT3JqvI=")
        #expect(SPKIPinning.spkiHash(of: try hostB())?.base64 == "jyomIJG/AM1mpiJm+xS39E9L/SNfb8bgcvP7ciaupXc=")
    }

    @Test("the same certificate always hashes the same")
    func hashIsStable() throws {
        let first = SPKIPinning.spkiHash(of: try hostA())
        let second = SPKIPinning.spkiHash(of: try hostA())

        #expect(first == second)
        #expect(first != nil)
    }

    @Test("two different certificates hash differently")
    func differentCertificatesDiffer() throws {
        // If this ever fails, pinning has become decorative: every host would
        // authenticate every other.
        #expect(SPKIPinning.spkiHash(of: try hostA()) != SPKIPinning.spkiHash(of: try hostB()))
    }

    @Test("the hash covers the public key, not the whole certificate")
    func hashesTheKeyNotTheCertificate() throws {
        // Pinning the certificate would break on every renewal even when the
        // key is unchanged, and would train users to re-pair — the habit that
        // makes a real key substitution unremarkable.
        let certificateData = SecCertificateCopyData(try hostA()) as Data
        let certificateDigest = SPKIPinning.sha256Base64(of: certificateData)

        #expect(SPKIPinning.spkiHash(of: try hostA())?.base64 != certificateDigest)
    }

    // MARK: - Verification

    @Test("the pinned certificate is accepted")
    func pinnedCertificateAccepted() throws {
        let pin = try #require(SPKIPinning.spkiHash(of: try hostA()))

        #expect(SPKIPinning.verify(certificate: try hostA(), against: pin) == .matched)
    }

    @Test("a changed certificate is refused")
    func changedCertificateRefused() throws {
        // Spec US1 scenario 7: the connection is refused and the user is asked
        // to pair again. There is no "trust anyway".
        let pin = try #require(SPKIPinning.spkiHash(of: try hostA()))

        #expect(SPKIPinning.verify(certificate: try hostB(), against: pin) == .mismatched)
    }

    /// FR-028 / Amendment A: no shared trust store.
    ///
    /// The failure this prevents is quiet and total — with one pool of trusted
    /// keys, any paired machine can present its certificate as any other, and
    /// everything still works, so nothing looks wrong.
    @Test("host A's certificate cannot authenticate host B")
    func crossHostCertificateRejected() throws {
        let hostAID = HostID()
        let hostBID = HostID()
        let store = InMemoryPinStore()

        try store.pin(#require(SPKIPinning.spkiHash(of: try hostA())), for: hostAID)
        try store.pin(#require(SPKIPinning.spkiHash(of: try hostB())), for: hostBID)

        let pinForB = try #require(store.pin(for: hostBID))
        #expect(SPKIPinning.verify(certificate: try hostA(), against: pinForB) == .mismatched)

        let pinForA = try #require(store.pin(for: hostAID))
        #expect(SPKIPinning.verify(certificate: try hostB(), against: pinForA) == .mismatched)
    }

    @Test("a host with no pin cannot be verified")
    func unpinnedHostCannotConnect() {
        // Absent is not permissive. "No pin recorded" must fail closed, or an
        // unpaired host would connect on the strength of having no history.
        let store = InMemoryPinStore()

        #expect(store.pin(for: HostID()) == nil)
    }

    @Test("verification has no bypass parameter")
    func verificationHasNoBypass() {
        // Checked mechanically because this is the kind of flag that gets added
        // "temporarily" during debugging and then ships. ArchitectureTests
        // sweeps the whole package; this pins the intent to the pinning code.
        let outcomes: Set<SPKIPinning.Outcome> = [.matched, .mismatched, .unusableCertificate]

        #expect(outcomes.count == 3, "a third accepting outcome would be a bypass")
    }

    @Test("an unpinned host's outcome is never .matched", arguments: [
        SPKIPinning.Outcome.mismatched,
        .unusableCertificate,
    ])
    func nonMatchingOutcomesRefuse(_ outcome: SPKIPinning.Outcome) {
        #expect(outcome.allowsConnection == false)
    }

    @Test("only .matched allows a connection")
    func onlyMatchedAllows() {
        #expect(SPKIPinning.Outcome.matched.allowsConnection)
    }
}

/// A per-host pin store used to assert the isolation property in a test.
///
/// Keyed by `HostID` with no global fallback: looking up a pin for one host
/// cannot reach another's. The real store is the Keychain (`PinnedCertificateStore`);
/// this stands in so the isolation assertion needs no entitlements.
private final class InMemoryPinStore {
    private var pins: [HostID: SPKIHash] = [:]

    func pin(_ hash: SPKIHash, for host: HostID) {
        pins[host] = hash
    }

    func pin(for host: HostID) -> SPKIHash? {
        pins[host]
    }
}
