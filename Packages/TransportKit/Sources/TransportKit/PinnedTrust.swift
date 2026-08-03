import Foundation
import LocalisModels
import Security

/// Performs one HTTP request.
///
/// A seam, so request construction and response interpretation are testable
/// without a socket — and so the pinned `URLSession` is built in exactly one
/// place rather than at each call site, where one plain `URLSession.shared`
/// would quietly opt out of pinning.
protocol HTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Decides whether a TLS handshake may proceed, given the host's pin
/// (constitution V, T022).
///
/// Split out of the `URLSession` delegate so the decision is a pure function
/// over a certificate chain. A rule that only runs inside a live handshake is a
/// rule nothing tests, and this one has to be right on a path that is invisible
/// when it works.
enum PinnedTrust {
    /// What to do with a handshake. **Two cases, one of which connects** —
    /// a third, permissive value would be the "trust anyway" that spec US1
    /// scenario 7 forbids.
    enum Disposition: Hashable, Sendable {
        case proceed
        case refuse
    }

    /// Evaluates a presented chain against the pin recorded at pairing.
    ///
    /// - Parameters:
    ///   - chain: certificates as presented, leaf first.
    ///   - pin: what was pinned for **this host**. Nil means the host is not
    ///     paired, which refuses — absent history is not permission.
    static func evaluate(chain: [SecCertificate], against pin: SPKIHash?) -> Disposition {
        // Only the leaf. The server proves possession of the leaf key alone, so
        // finding the pinned key further up the chain proves nothing — an
        // attacker can present any intermediate they like.
        guard let pin, let leaf = chain.first else { return .refuse }

        return SPKIPinning.verify(certificate: leaf, against: pin).allowsConnection ? .proceed : .refuse
    }
}

/// Enforces one host's pin on every connection made through its session
/// (T022).
///
/// One delegate per host, holding one pin. Not a registry keyed by hostname:
/// a shared delegate is a shared trust store by another name, and it would let
/// host A's certificate satisfy a connection to host B (FR-028).
final class PinnedSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    private let pin: SPKIHash?

    init(pin: SPKIHash?) {
        self.pin = pin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Not a server-trust challenge. We have nothing to offer and must
            // not fall back to the default handling, which could accept a
            // system-trusted certificate we never pinned.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []

        switch PinnedTrust.evaluate(chain: chain, against: pin) {
        case .proceed:
            // The pin *replaces* CA validation — the bridge is self-signed, so
            // the system evaluation would fail on a certificate that is exactly
            // the one we pinned.
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .refuse:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// `URLSession` pinned to one host.
struct PinnedHTTP: HTTPPerforming {
    private let session: URLSession

    /// - Parameter pin: the host's pinned SPKI, or nil during pairing, when
    ///   there is nothing to pin against yet.
    init(pin: SPKIHash?, configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(
            configuration: configuration,
            delegate: PinnedSessionDelegate(pin: pin),
            delegateQueue: nil
        )
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalisError.malformedResponse
        }
        return (data, http)
    }
}
