import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// Removing one host's credentials, for the code that acts on a refusal.
///
/// Separate from `PinReading` rather than an extension of it. `PinReading` is
/// deliberately read-only and says so — a protocol that also offered deletion
/// would put "wipe this machine's trust anchor" within reach of every type that
/// merely wanted to draw a row. Handing the destructive capability to exactly
/// one caller is the point.
protocol HostCredentialWriting: PinReading {
    /// Removes the token and the pin for `host` and nothing else (FR-027).
    func removeCredentials(for host: HostID) throws
}

/// The real Keychain already has exactly this shape.
extension HostCredentialStore: HostCredentialWriting {}

/// Acts on a host that refused us: clears what must go, keeps what must stay.
///
/// **Why this is its own type in the app target.** The two halves of a machine's
/// identity live in packages that cannot see each other — `SessionStore` keeps
/// the record and `TransportKit` keeps the credential, and neither depends on
/// the other (they share only `LocalisModels`). So "unpair this host" cannot be
/// expressed inside either one, and `BridgeClient`, which is where a 401 is
/// first understood, does not import `SessionStore` at all. The join has to
/// happen here, next to `HostAssembly`, which joins the same two halves in the
/// reading direction.
///
/// **Why the input is a `LocalisError` and not a `HostUnreachableReason`.**
/// The reason enum has one `unauthorized` case covering both 401 codes, and the
/// two demand opposite actions — `token_revoked` must clear the Keychain and
/// `invalid_token` must not (`BridgeClient.error`, and
/// `LocalisErrorTests.revokedTokenIsItsOwnCase`). Taking the reason as input
/// would mean deciding on a value from which the distinction has already been
/// erased, so the decision would be made by whichever caller mapped it. The
/// error keeps both codes apart, so it is what arrives here; the reason is what
/// this produces for the UI, not what it consumes. #30 tracks giving
/// `HostUnreachableReason` the missing case so the display can distinguish them
/// too.
///
/// **The operation is defined by what it must not do.** Writing `.revoked` is
/// one line and any implementation gets it right. What goes wrong quietly is
/// the blast radius: another machine's credential removed along with this one,
/// or the conversations deleted because unpairing sounds like it should clean
/// up. Both are invisible when they happen and surface much later, as a Mac
/// that inexplicably needs re-pairing or a history that is gone.
///
/// Sessions are never touched here — see FR-027 and FR-036. A machine the user
/// stopped trusting keeps every word that was said on it; it simply cannot be
/// sent to any more, which follows from `canConnect` rather than from deletion.
struct HostRevocation: Sendable {
    private let repository: any SessionRepository
    private let credentials: any HostCredentialWriting

    init(
        repository: any SessionRepository,
        credentials: any HostCredentialWriting = HostCredentialStore()
    ) {
        self.repository = repository
        self.credentials = credentials
    }

    /// Applies whatever `error` implies about `host`'s pairing.
    ///
    /// Most errors imply nothing and this returns having done nothing — a
    /// timeout says the Mac is asleep, not that the credential is bad.
    ///
    /// A host that is not on file is a no-op rather than an error: a refusal can
    /// arrive for a machine the user removed while the request was in flight,
    /// and reporting that would be a failure about something already gone.
    ///
    /// - Throws: whatever the Keychain throws. **Deliberately not swallowed.**
    ///   A failed deletion with a stored state of `.revoked` would tell the user
    ///   the machine is unpaired while its credential is still on disk, and
    ///   FR-027's "zero residue" would be false with nothing to show for it.
    ///   The store is written *after* the Keychain for the same reason: if the
    ///   deletion fails, the record still says `.paired`, which is at least
    ///   true.
    func apply(_ error: LocalisError, to host: HostID) async throws {
        guard let outcome = Self.outcome(of: error) else { return }
        guard let stored = try await repository.host(id: host) else { return }

        if outcome.clearsCredentials {
            try credentials.removeCredentials(for: host)
        }
        try await repository.save(outcome.applied(stored))
    }

    /// What an error does to the host's pairing, or nil if it does nothing.
    ///
    /// **Deliberately a small allow-list rather than a `switch` over every
    /// case.** `LocalisError` has upwards of fifteen cases and gains more as
    /// the contract grows; an exhaustive switch here would force every new
    /// transport error to answer a question about pairing that almost none of
    /// them have anything to do with, and the easy answer under that pressure
    /// is to copy the neighbouring line. Defaulting to "changes nothing" is
    /// both the truth for the overwhelming majority and the safe direction to
    /// be wrong in: the cost is a stale credential surviving until the next
    /// `token_revoked`, against the cost of a wrongly-cleared pairing, which
    /// is a user sent to re-scan a code for a machine that never refused them.
    private static func outcome(of error: LocalisError) -> Outcome? {
        switch error {
        case .tokenRevoked:
            // 401 `token_revoked` — the Mac revoked this device, one-way
            // (bridge-protocol.md :118). `unpaired()` clears the pinned SPKI as
            // well as setting the state, so the record and the Keychain agree
            // after this runs.
            Outcome(clearsCredentials: true) { $0.unpaired() }

        case .certificatePinMismatch:
            // Constitution V: no override, and it must be *named*. Folding this
            // into `.revoked` would label it "Unpaired" and invite a re-pair —
            // which would pin whatever certificate is now being presented, i.e.
            // exactly the attack the pin exists to stop. The old pin stays so
            // the UI can point at this host specifically, which is why this
            // does not clear credentials.
            Outcome(clearsCredentials: false) { $0.certificateChanged() }

        default:
            // Includes `.unauthorized` (401 `invalid_token`). The contract
            // disagrees with itself: the prose at :118 names only
            // `token_revoked` as requiring the token to be cleared, while the
            // error table at :587 lists both codes against one action.
            //
            // The narrow reading wins until that is settled, because the two
            // mistakes are not symmetric. Clearing on the broad reading sends a
            // user who did nothing wrong back to scan a pairing code after a
            // clock skew or a flaky middlebox; not clearing leaves a dead token
            // in place until the revocation that `token_revoked` exists to
            // announce. `BridgeClient.error` already splits the two codes on
            // exactly this argument, and `LocalisErrorTests` guards the split.
            //
            // Sent to TL as a contract question. If the table wins, add
            // `.unauthorized` beside `.tokenRevoked` above and invert
            // `unauthorizedDoesNotClearCredentials`.
            nil
        }
    }

    /// One error's effect: whether the Keychain is cleared, and the state
    /// transition applied to the record.
    private struct Outcome {
        let clearsCredentials: Bool
        let applied: @Sendable (LocalisHost) -> LocalisHost

        init(clearsCredentials: Bool, applied: @escaping @Sendable (LocalisHost) -> LocalisHost) {
            self.clearsCredentials = clearsCredentials
            self.applied = applied
        }
    }
}
