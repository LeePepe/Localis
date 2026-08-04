import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// The one thing `HostAssembly` needs from the Keychain.
///
/// Narrow on purpose. `HostCredentialStore` can also read and write tokens and
/// delete credentials; none of that belongs in this join, and a protocol that
/// exposed it would let a future edit reach for it here. Reading a pin is the
/// whole contract.
///
/// It exists so tests can substitute a fake: the real Keychain fails
/// differently in CI than on a developer's machine, and a suite that goes red
/// for reasons unrelated to its subject teaches people to ignore it.
protocol PinReading: Sendable {
    func pin(for host: HostID) throws -> SPKIHash?
}

/// The real Keychain already has exactly this shape.
extension HostCredentialStore: PinReading {}

/// Joins a stored machine to its Keychain pin.
///
/// **Why this type exists at all.** A machine the user paired lives in two
/// places on purpose: `SessionStore` keeps the record — name, address, pairing
/// state — and the Keychain keeps the pin, which is the trust anchor and must
/// have exactly one owner (constitution I, FR-028). Neither half is a usable
/// host on its own. The store deliberately has no pin column, so every record
/// it returns has `pinnedSPKI == nil` and `canConnect == false`; the Keychain
/// has a pin but nothing to attach it to.
///
/// This is the join, and it is meant to be the **only** one. A loose helper
/// that callers could bypass would put us back where the pin is patched in by
/// whoever remembers to — and a `canConnect` that is true only after certain
/// callers do extra work is a trap whose symptom looks like a network problem.
///
/// **What it must never do.** It reads pins; it never writes them, never
/// returns one to a caller, and never puts one anywhere it could be logged.
/// The token is not touched here at all: it stays in the Keychain and goes
/// straight to the transport that needs it.
struct HostAssembly: Sendable {
    private let repository: any SessionRepository
    private let credentials: any PinReading

    init(repository: any SessionRepository, credentials: any PinReading = HostCredentialStore()) {
        self.repository = repository
        self.credentials = credentials
    }

    /// The complete host for `id`, or nil if no such machine is on file.
    ///
    /// A machine with no pin comes back exactly as the store had it —
    /// `canConnect == false` — rather than being treated as an error. That is
    /// the normal state for a machine the user added but has not yet paired,
    /// and it is also the state a partially-completed pairing leaves behind.
    func host(id: HostID) async throws -> LocalisHost? {
        guard let stored = try await repository.host(id: id) else { return nil }
        return try joined(stored)
    }

    /// Every machine on file, each joined to its pin.
    ///
    /// One Keychain read per host. That is fine at this scale — the list is the
    /// user's own Macs — and the alternative, a bulk read, would mean holding
    /// several pins in memory at once for no benefit.
    func hosts() async throws -> [LocalisHost] {
        try await repository.hosts().map(joined)
    }

    /// Attaches the pin, if there is one.
    ///
    /// **A Keychain failure must not silently produce an unconnectable host.**
    /// Swallowing the error here would turn "the Keychain is locked" into "this
    /// machine is not paired", which sends the user to re-pair a machine that
    /// is already paired — and re-pairing is exactly the operation that
    /// overwrites the pin we failed to read. So the error propagates.
    private func joined(_ stored: LocalisHost) throws -> LocalisHost {
        // Only a machine that got as far as `.paired` may carry a pin. Reading
        // for the others is not merely wasteful: a pin found under a host in
        // any other state is residue from an unpairing that did not finish, and
        // attaching it would resurrect a trust anchor the user revoked
        // (FR-027).
        guard stored.pairingState == .paired else { return stored }
        guard let pin = try credentials.pin(for: stored.id) else {
            // Paired, but the pin is gone. `canConnect` stays false, which is
            // the fail-closed answer: we cannot check the certificate, so we do
            // not offer the connection. Deliberately not an error — a restored
            // device backup carries the store but not the Keychain, and that
            // user needs to see their machine and be told to pair it again.
            return stored
        }
        return stored.paired(pinning: pin)
    }
}
