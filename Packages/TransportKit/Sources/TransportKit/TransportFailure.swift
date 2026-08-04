import Foundation
import LocalisModels

/// Turns a transport-layer failure into the error the rest of the app reasons
/// about.
///
/// **Why this is one function and not two catch blocks.** Both request paths
/// used to end in their own `catch { throw LocalisError.unreachable }`. That
/// answered "the Mac is asleep or off the network" for every failure the
/// network stack could produce — including a certificate that did not match
/// the pin, which is the one failure constitution V forbids overriding and the
/// one the user most needs named. Two copies of a rule are two places for it
/// to drift, and the rule here decides what the user is told to go fix.
///
/// **The bias is toward saying less.** Anything this cannot place stays
/// `.unreachable`. Naming a specific cause on a guess is exactly the defect
/// being fixed, only pointed at a different wrong half — and "your host may be
/// impersonated" is a far more alarming thing to say wrongly than "your host
/// is not answering" (#34).
enum TransportFailure {
    /// Classifies one error thrown by the transport.
    ///
    /// - Returns: a `LocalisError` naming which half of the system failed.
    ///   Errors that are already `LocalisError` pass through untouched — one
    ///   that crossed a boundary already carries a cause, and re-deriving it
    ///   from its transport shape can only make it vaguer.
    static func classify(_ error: Error) -> LocalisError {
        if let ours = error as? LocalisError { return ours }
        // Not a `URLError`, so there is no code to read — but the `NSError`
        // identity is still there, and this is the vaguest answer this function
        // gives, which makes it the one most worth being able to look up (#34).
        guard let url = error as? URLError else {
            return .unreachable(diagnostic: TransportDiagnostic(error))
        }

        switch url.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed:
            // The handshake was refused on the certificate itself. For a bridge
            // this always means the pin: its certificate is self-signed, so the
            // system's default policy rejects the *correct* certificate too —
            // reaching here at all means our pinning delegate did not get to
            // decide, or decided against.
            return .certificatePinMismatch

        case .cancelled:
            // Reported for every cancellation, including our pinning delegate
            // refusing a challenge. `.cancelled` is true under either reading;
            // claiming the pin failed would be a guess, and claiming the host
            // is offline (the old behaviour) is false under both.
            return .cancelled

        default:
            // Includes every outage code (`cannotConnectToHost`, `timedOut`,
            // `dnsLookupFailed`, …). They are not enumerated because they and
            // the unrecognised errors want the same answer, and a list that
            // changes nothing is a list that will drift out of date without
            // any test noticing.
            //
            // Not enumerating them is affordable precisely because the code
            // rides along in the diagnostic (#34): the category stays coarse,
            // and a log still distinguishes a timeout from a DNS failure from
            // something this build has never seen.
            return .unreachable(diagnostic: TransportDiagnostic(error))
        }
    }
}
