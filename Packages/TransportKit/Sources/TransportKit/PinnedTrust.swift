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
final class PinnedSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let pin: SPKIHash?
    private let observer: (@Sendable (ChallengeOutcome) -> Void)?

    /// What the delegate did with one challenge.
    ///
    /// **Why this exists at all.** The third way pinning can fail is that this
    /// delegate is never invoked — misconfigured session, a stray
    /// `URLSession.shared`, a challenge type that never reaches us. From the
    /// caller that failure is a connection error, indistinguishable from a
    /// rejected certificate or an unreachable host, and it points at a
    /// completely different cause. Inferring "the delegate ran" from an error
    /// code is inference; this is a record.
    ///
    /// Carries no certificate bytes and no host identity — only which branch was
    /// taken, so it can never become a channel for anything sensitive.
    enum ChallengeOutcome: String, Sendable {
        /// A server-trust challenge whose chain satisfied the pin.
        case proceeded
        /// A server-trust challenge whose chain did not satisfy the pin, or
        /// which arrived with no pin to check against.
        case refused
        /// Not a server-trust challenge; cancelled without consulting the pin.
        case notServerTrust
    }

    /// - Parameter observer: called once per challenge, with the branch taken.
    ///   Nil in production — nothing in the app needs it, and a default of nil
    ///   keeps every existing call site unchanged.
    init(pin: SPKIHash?, observer: (@Sendable (ChallengeOutcome) -> Void)? = nil) {
        self.pin = pin
        self.observer = observer
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        decide(challenge, completionHandler)
    }

    /// The same decision, for challenges delivered to the **task** delegate.
    ///
    /// **Not redundant with the session-level method above.** `URLSession`'s
    /// async APIs do not consult the session delegate for authentication:
    /// `bytes(for:)` never calls `urlSession(_:didReceive:completionHandler:)`,
    /// so a session configured exactly as this one is — pinned delegate and all
    /// — falls back to the system's default trust evaluation, which rejects the
    /// self-signed certificate the pin exists to accept. The symptom is
    /// `-1202`, "the certificate for this server is invalid", which points at
    /// the server rather than at the caller and reads as a certificate problem.
    ///
    /// Conforming to `URLSessionTaskDelegate` and passing this object as the
    /// task delegate is what routes those challenges back here, so both the
    /// plain and the streamed paths are judged by one pin (#32).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        decide(challenge, completionHandler)
    }

    /// One decision, shared by both delegate entry points.
    ///
    /// Deliberately not duplicated per entry point: two copies of a trust rule
    /// are two places for it to drift, and the whole failure this fixes was one
    /// path being judged differently from another.
    private func decide(
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Not a server-trust challenge. We have nothing to offer and must
            // not fall back to the default handling, which could accept a
            // system-trusted certificate we never pinned.
            observer?(.notServerTrust)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []

        switch PinnedTrust.evaluate(chain: chain, against: pin) {
        case .proceed:
            // The pin *replaces* CA validation — the bridge is self-signed, so
            // the system evaluation would fail on a certificate that is exactly
            // the one we pinned.
            observer?(.proceeded)
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .refuse:
            observer?(.refused)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// `URLSession` pinned to one host.
struct PinnedHTTP: HTTPPerforming {
    /// Internal rather than private so the `HTTPStreaming` conformance can reach
    /// it from its own file. Still not `public`: an unpinned session must not be
    /// constructible from outside this package.
    let session: URLSession

    /// The same delegate the session holds, kept so it can also be handed to
    /// individual tasks.
    ///
    /// `URLSession`'s async APIs bypass the session delegate for authentication
    /// challenges, so the streamed path has to pass this explicitly as a
    /// task delegate. Reading it back off `session.delegate` would work but
    /// would need a downcast at each use — and a downcast that silently fails
    /// would restore exactly the unpinned behaviour this fixes.
    let pinnedDelegate: PinnedSessionDelegate

    /// - Parameters:
    ///   - pin: the host's pinned SPKI. **Nil refuses every connection** —
    ///     `PinnedTrust.evaluate` treats absent history as absent permission, so
    ///     nil is "cannot connect", not "trust on first use". Pairing therefore
    ///     needs the pin it is about to verify, obtained out of band.
    ///   - observer: see `PinnedSessionDelegate.ChallengeOutcome`. Nil in
    ///     production; supplied by the live-bridge harness to record that the
    ///     delegate ran at all rather than inferring it from an error code.
    init(
        pin: SPKIHash?,
        configuration: URLSessionConfiguration = .ephemeral,
        observer: (@Sendable (PinnedSessionDelegate.ChallengeOutcome) -> Void)? = nil
    ) {
        let delegate = PinnedSessionDelegate(pin: pin, observer: observer)
        pinnedDelegate = delegate
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
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
