import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// Pairing one Mac: what is on the network, and the exchange that makes one of
/// them usable.
///
/// **What was missing before this existed.** `BridgePairing` could pair, and
/// nothing called it. Every host the app has ever recorded arrives `.discovered`
/// through `LocalisHost(adopting:)`, and the only `.paired` record any developer
/// had ever seen was `DemoSeed` writing the state directly — so the transition
/// the whole trust model is built around had no production caller at all. That
/// is the same shape as B-1's missing `hosts()` call: every symbol referenced,
/// every suite green, and the app physically unable to do the one thing it is
/// for.
///
/// `@MainActor` for the same reason `HostListModel` is: it publishes to SwiftUI
/// and nothing else. The network and the repository are awaited off this actor.
@MainActor
@Observable
final class HostPairingModel {
    /// Machines seen on the network, newest information last.
    ///
    /// Sightings, not hosts — nothing here is trusted, pinned or stored. Adding
    /// a row costs nothing and confers nothing; only `pair` writes.
    private(set) var discovered: [DiscoveredHost] = []
    /// Non-nil while an exchange is in flight, naming the machine, so the
    /// screen can disable the form without also having to know which row.
    private(set) var pairingWith: DiscoveredHost?
    /// Why the last attempt failed, in the user's words. Cleared when the next
    /// attempt starts.
    ///
    /// **Three different failures must produce three different sentences.**
    /// A wrong code, an invalidated pairing session and a certificate that does
    /// not match demand three unrelated actions — retype the digits, restart
    /// pairing on the Mac, and stop, respectively. `LocalisError.userMessage`
    /// already keeps them apart; this string is that value, never a summary of
    /// it.
    private(set) var failure: String?
    /// The machine that just paired, so the screen can close itself and the
    /// host list can reload. Not a `LocalisHost`: the caller reads through
    /// `HostAssembly` like every other reader, rather than being handed a value
    /// that has bypassed the join.
    private(set) var pairedHost: HostID?

    private let repository: any SessionRepository
    /// The store joined to the Keychain.
    ///
    /// **Recognition has to read through this, not off the repository.** The
    /// store deliberately has no pin column, so every record `repository.hosts()`
    /// returns has `pinnedSPKI == nil` — and `HostRecognition` matches on the
    /// pin. Given the bare store list, both of its `first(where:)` clauses fail
    /// for every machine on file, the outcome is `.unknown` every time, and each
    /// pairing writes a *new* record for a Mac already recorded. That is the
    /// duplicate row FR-031 exists to prevent, arrived at without a single
    /// failing assertion anywhere: the pairing succeeds, the pill says Paired,
    /// and the second row appears next to the first.
    ///
    /// Read off `StoredMapping` rather than assumed — `pinnedSPKI: nil` is
    /// written unconditionally there, with a comment saying it is not a gap.
    /// `HostAssembly` is the one place the two halves are put back together, and
    /// this is one of its callers.
    private let assembly: HostAssembly
    /// Exchanges the code for a token and records the pin.
    ///
    /// Injected rather than constructed, for the reason `HostPairing`'s own doc
    /// comment gives: the failures that matter here — a rejected code, a dead
    /// session, a certificate that does not match — are each reproducible only
    /// against a real Mac put into that exact state, and the last of them means
    /// changing a Mac's certificate. Behind this seam a test states what each
    /// one must leave behind.
    private let pairing: any HostPairing
    private let discovery: any HostDiscovering

    /// Cancelled when the screen goes away. A browse left running holds the
    /// radio awake for a stream nobody is reading.
    ///
    /// **`@ObservationIgnored` is load-bearing, not tidiness.** Without it the
    /// `@Observable` macro rewrites this into accessors that are isolated to
    /// this actor, and `deinit` — which is not — cannot then touch it: *"main
    /// actor-isolated property 'browse' can not be referenced from a nonisolated
    /// context."* It is also simply not UI state: nothing renders it, and
    /// registering a dependency on it would wake every observer of this model
    /// each time browsing starts or stops.
    @ObservationIgnored private var browse: Task<Void, Never>?

    init(
        repository: any SessionRepository,
        pairing: any HostPairing = BridgeHostPairing(),
        discovery: any HostDiscovering = BonjourHostDiscovery(),
        credentials: any PinReading = HostCredentialStore()
    ) {
        self.repository = repository
        self.assembly = HostAssembly(repository: repository, credentials: credentials)
        self.pairing = pairing
        self.discovery = discovery
    }

    deinit {
        browse?.cancel()
    }

    // MARK: - Discovery

    /// Starts browsing, if it is not already running.
    ///
    /// Idempotent because SwiftUI runs `.task` again on every re-appearance, and
    /// a second browse would double every row rather than refresh it.
    func startDiscovery() {
        guard browse == nil else { return }
        let stream = discovery.hosts()
        // Inherits this actor, so `merge` needs no hop — the `Task` is started
        // from `@MainActor` context and stays there. Written without an `await`
        // because there is nothing to await: the compiler says so ("no 'async'
        // operations occur within 'await' expression"), and leaving the await in
        // would suggest a suspension point that does not exist.
        browse = Task { [weak self] in
            for await host in stream {
                guard let self else { return }
                self.merge(host)
            }
        }
    }

    /// Stops browsing and forgets what was seen.
    ///
    /// The list is not kept across visits on purpose: a sighting is a claim
    /// about right now, and a stale row invites the user to pair with a machine
    /// that left the network — which fails as a timeout, some seconds later,
    /// with nothing on screen explaining why that row was ever offered.
    func stopDiscovery() {
        browse?.cancel()
        browse = nil
        discovered = []
    }

    private func merge(_ host: DiscoveredHost) {
        discovered = Self.merging(host, into: discovered)
    }

    /// Adds a sighting, or updates the one it supersedes.
    ///
    /// **The stream is deliberately not deduplicated** (`BridgeDiscovery.hosts`
    /// says so): a machine re-advertising after a DHCP renewal is reported
    /// again, and that repeat *is* the address change. A list is the other
    /// side of that — the user is choosing a machine, and the same Mac offered
    /// five times is five chances to pick the wrong one. So the collapsing
    /// happens here, where "which of these are the same machine" is the
    /// question being asked, rather than in the stream, where it would discard
    /// the relocation.
    ///
    /// Keyed by `isSameMachine`, which is also what the screen keys its rows and
    /// its selection on — see that function for why there is only one of it.
    ///
    /// Static and pure so the rule can be stated without a network.
    static func merging(_ host: DiscoveredHost, into hosts: [DiscoveredHost]) -> [DiscoveredHost] {
        let index = hosts.firstIndex { isSameMachine(host, as: $0) }
        guard let index else { return hosts + [host] }
        // A new array rather than an in-place write: the project's rule, and it
        // also keeps this function usable as a plain expression in a test.
        var updated = hosts
        updated[index] = host
        return updated
    }

    /// Whether two sightings are the same Mac, for this screen's purposes.
    ///
    /// **One rule, because two of them is a bug and not a style question.**
    /// `merging` collapses a relocated machine onto its existing row, so that
    /// row's value is *replaced* — new endpoint, same machine. Anything else
    /// that decides "same machine" differently then disagrees with the list
    /// about which row is which. Concretely, when the screen keyed its `ForEach`
    /// and its selection on the endpoint alone: a DHCP renewal collapsed the row
    /// here but changed its identity there, so SwiftUI tore the row down and
    /// rebuilt it, and the selection stopped matching anything. The part that is
    /// not cosmetic is what follows — a selection held as a *value* still
    /// carried the old address, so tapping Pair sent the exchange to where the
    /// Mac used to be. It fails as a timeout, some seconds later, against a
    /// machine that was on screen and reachable the whole time.
    ///
    /// Keyed on `bridgeID` when the bridge sends one and on the endpoint
    /// otherwise. **Not on the display name**: two Macs may share one, and
    /// collapsing them would hide a machine entirely.
    ///
    /// Note what this deliberately is *not*: an identity authority. It decides
    /// which row of a browse list a sighting belongs to, and nothing about it
    /// reaches the store — `HostRecognition` answers "is this a Mac we already
    /// have", against the pin, and Amendment A §1.6 is explicit that a `hid`
    /// alone does not settle that question.
    ///
    /// Written as equality of `DiscoveredHost.identity` rather than as its own comparison,
    /// so the list's rule and the view's `ForEach` key cannot drift: they are
    /// not two implementations that agree, they are one.
    ///
    /// **What that costs, stated rather than discovered.** An equivalence
    /// relation is not optional here — a `ForEach` key *is* one, and a rule that
    /// answered differently depending on which sighting was asked first would
    /// collapse rows in an order nobody could predict. The earlier rule was
    /// exactly that: it merged a `hid`-carrying sighting onto a `hid`-less row
    /// at the same address, but not the reverse, so whether the user saw one row
    /// or two depended on whether they typed the address before or after Bonjour
    /// answered. Making it symmetric loses the case where it worked: a Mac added
    /// by hand *and* found by Bonjour is now two rows. That is a duplicated row
    /// in a picker, not a duplicated host — pairing either one goes through
    /// `HostRecognition`, which matches on the pin and produces one record. The
    /// fix belongs in whatever can tell those two sightings are one machine
    /// before either is paired, and nothing here can.
    static func isSameMachine(_ host: DiscoveredHost, as other: DiscoveredHost) -> Bool {
        host.identity == other.identity
    }

    /// The sighting that now stands for `host`, or nil if it has gone.
    ///
    /// The screen holds its selection as a value while the list underneath keeps
    /// moving: a machine that relocates is the *same* selection pointing at a
    /// stale endpoint. Re-resolving through the identity rule is what sends the
    /// exchange to where the Mac is now rather than where it was when the row
    /// was tapped.
    func current(_ host: DiscoveredHost) -> DiscoveredHost? {
        discovered.first { Self.isSameMachine(host, as: $0) }
    }

    /// Offers a machine the user typed the address of (FR-001).
    ///
    /// The path Bonjour cannot serve — Tailscale, a VPN and most guest networks
    /// carry no multicast. Validation is `DiscoveredHost(manualEndpoint:)`, the
    /// same rule a broadcast sighting goes through, including the HTTPS-only
    /// check: a manual field is the obvious place a plaintext fallback would
    /// reappear.
    ///
    /// **Nothing is stored here, and that is a deliberate difference from
    /// `HostListModel.addHost(typedAddress:)`.** That method saves a record
    /// immediately, which is right for a list of machines the user is keeping
    /// but wrong ahead of pairing: a stored `.discovered` host has no pin, and
    /// `HostRecognition` matches on the pin — so `pair` would not recognise the
    /// row that was just written and would create a **second** record for the
    /// same machine. Read off `HostRecognition.recognise` rather than assumed:
    /// with `pinnedSPKI == nil` and `bridgeID == nil` the host matches neither
    /// of its two `first(where:)` clauses, so the outcome is `.unknown`. The
    /// duplicate row is exactly what FR-031 exists to prevent.
    ///
    /// - Throws: `LocalisError.invalidInput(field: "endpoint")` for an address
    ///   that is not usable, before anything is offered.
    /// - Returns: the sighting now standing for that address, so the caller can
    ///   select it without re-parsing the text or guessing at a position in the
    ///   list. It is not necessarily a *new* row: a typed address matching a
    ///   machine already listed replaces that row and appends nothing.
    @discardableResult
    func addManualHost(address text: String) throws -> DiscoveredHost {
        let host = try DiscoveredHost(manualEndpoint: text)
        discovered = Self.merging(host, into: discovered)
        return host
    }

    // MARK: - Pairing

    /// Exchanges the six digits shown on the Mac for a token, pinning the
    /// fingerprint printed beside them (FR-002, contract §1).
    ///
    /// Both values come off the Mac's own screen through the same out-of-band
    /// channel, which is what makes the fingerprint a trust anchor rather than
    /// something the bridge asserts about itself — so the request goes out on an
    /// already-pinned connection and there is no unpinned first step to support
    /// (Amendment E §3).
    ///
    /// Does not throw. Every outcome is a sentence on this screen, and a screen
    /// that also threw would give the caller a second place to render the same
    /// failure — the split that lets two wordings drift apart.
    ///
    /// `host` is what the user tapped, which may since have moved: it is
    /// re-resolved through `current(_:)` so the exchange goes to the address the
    /// machine answers on now.
    ///
    /// **Falling back to the value passed in, rather than refusing.** I wrote
    /// the refusal first and backed it out: a sighting the list has never heard
    /// of is not a state this screen can reach — every host that gets here came
    /// from `discovered`, either as a tapped row or as what `addManualHost`
    /// returned — so the refusal's only reachable effect was to invent a
    /// user-facing failure for a case no user can produce. Re-resolution is the
    /// part that fixes a real bug; the guard was scope I added on top of it.
    func pair(with host: DiscoveredHost, code: String, fingerprint: String) async {
        failure = nil
        pairedHost = nil

        do {
            let code = try Self.validatedCode(code)
            let spki = try Self.validatedFingerprint(fingerprint)
            try await exchange(with: current(host) ?? host, code: code, spki: spki)
        } catch {
            failure = Self.sentence(for: error)
        }
        pairingWith = nil
    }

    /// What the user is told, for every way this can end.
    ///
    /// **`invalidInput` is intercepted rather than passed through, and the
    /// reason is what it renders as.** `LocalisError.userMessage` builds that
    /// case as `"Please check the \(field) field."`, so the two fields this
    /// screen validates would surface as *"Please check the fingerprint field."*
    /// and *"Please check the code field."* — a wire-side identifier
    /// interpolated into a sentence shown to a person, naming neither what is
    /// wrong nor what to do about it.
    ///
    /// It is also the one path that would bypass this project's
    /// no-hardcoded-strings rule by routing around it: `userMessage` is
    /// deliberately **not** localized (its own doc says *"Callers localize at
    /// the UI boundary"*), and this screen is that boundary. Every other case
    /// is a whole sentence written for a user, so those pass through unchanged
    /// — the wording for a rejected code, a dead session and a changed
    /// certificate lives in `LocalisError` and must not be duplicated here.
    ///
    /// Deliberately not fixed in `LocalisError`: that is LocalisModels' layer,
    /// its wording is shared with every other caller, and a cross-layer edit to
    /// suit one screen is how a vocabulary drifts.
    private static func sentence(for error: some Error) -> String {
        guard let error = error as? LocalisError else {
            return String(localized: "Pairing didn't finish. Please try again.")
        }
        switch error {
        case .invalidInput(let field) where field == codeField:
            return String(localized: "That code should be six digits. Check the code on the Mac.")
        case .invalidInput(let field) where field == fingerprintField:
            return String(
                localized: "That fingerprint looks incomplete. Copy the whole pin line from the Mac."
            )
        default:
            return error.userMessage
        }
    }

    private func exchange(with host: DiscoveredHost, code: String, spki: SPKIHash) async throws {
        let record = try await resolvedRecord(for: host, presenting: spki)

        pairingWith = host
        // Saved before the request so the list reads "Pairing…" while the user
        // is looking at it. It is also what makes a crash mid-exchange visible
        // afterwards rather than silent: the record says something happened.
        try await repository.save(record.beginningPairing())

        let result: PairedBridge
        do {
            result = try await pairing.pair(
                host: record.id,
                endpoint: host.endpoint,
                code: code,
                pinning: spki
            )
        } catch {
            // **Rolled back to the state it had before this attempt, not to
            // `.discovered`.** For a machine being paired for the first time
            // those are the same value. For one being re-paired they are not,
            // and demoting a working pairing because a retype went wrong would
            // take away a Mac the user can still use — a failure of this screen
            // reaching out and breaking something it was not asked about.
            //
            // Restored before rethrowing, and the rethrow is what puts the
            // reason on screen. Swallowing here would leave a rolled-back
            // record with no explanation, which reads as the tap not registering.
            try await repository.save(record)
            throw error
        }

        try await repository.save(Self.paired(record, with: result, pinning: spki))
        pairedHost = record.id
    }

    /// The record this pairing belongs to: the machine already on file, or a
    /// new one.
    ///
    /// **This is FR-031, and it is the reason the fingerprint is needed before
    /// the request rather than after it.** A Mac that changed address
    /// re-advertises as an unfamiliar endpoint; recognising it by the
    /// certificate the user just read off its screen keeps its id, and with it
    /// every conversation attributed to it. Creating a second record instead
    /// would strand that history behind a row the user cannot tell from the
    /// first.
    ///
    /// The rule itself is `HostRecognition`, reached through
    /// `DiscoveredHost.recognised(presenting:among:)`. Deliberately not
    /// reimplemented: it is subtle, it fails silently in both directions, and it
    /// must read identically wherever it is applied.
    private func resolvedRecord(
        for host: DiscoveredHost,
        presenting spki: SPKIHash
    ) async throws -> LocalisHost {
        // Joined to the Keychain first — see `assembly`. Off the bare store
        // every record has no pin, and recognition would answer `.unknown` for
        // a machine sitting right there in the list.
        let known = try await assembly.hosts()

        switch host.recognised(presenting: spki, among: known) {
        case .trusted(let id), .needsPairing(let id):
            guard let existing = known.first(where: { $0.id == id }) else {
                // The outcome named an id that is not in the list it was
                // computed from. Nothing can make that true, so no record is
                // invented to cover it — inventing one would silently start a
                // second history for this machine.
                throw LocalisError.malformedResponse
            }
            // Same machine, wherever it is answering now.
            return existing.relocated(to: host.endpoint)

        case .untrusted(let id):
            // A machine on file whose pinned certificate is **not** the one the
            // user just typed. Recognition says the two are different machines
            // regardless of what `bridge_id` claims (Amendment A §1.6), and the
            // record is left exactly as it is: pairing from here would overwrite
            // a good pin with a stranger's, which is the substitution pinning
            // exists to deny (constitution V, no override).
            //
            // **What this costs, stated rather than glossed.** A user whose
            // bridge was genuinely reinstalled — new key, same `hid` — is stuck
            // on this screen: the way out is an explicit unpair, and this app
            // has no unpair action yet (`HostRevocation` has no production
            // caller — see its own note). The alternative is worse: a screen
            // that re-pins on demand makes a real key substitution look exactly
            // like a reinstall, and the user has no way to tell which one they
            // just approved.
            _ = id
            throw LocalisError.certificatePinMismatch

        case .unknown:
            // `.discovered`, no pin, a freshly minted local id — see
            // `LocalisHost(adopting:)`. Nothing from the advertisement is
            // trusted; it is a record that this machine was offered.
            return LocalisHost(adopting: host)
        }
    }

    /// The record as it stands after a successful exchange.
    ///
    /// Static and pure so what pairing writes can be stated without a network
    /// or a store.
    ///
    /// **The pin goes to the Keychain, inside `BridgePairing`, and nowhere
    /// else.** `paired(pinning:)` puts it on the in-memory value so
    /// `canConnect` is true for the caller that reads this back through
    /// `HostAssembly`; `SessionStore` has no pin column and must not gain one
    /// (constitution I, FR-028).
    static func paired(
        _ record: LocalisHost,
        with result: PairedBridge,
        pinning spki: SPKIHash
    ) -> LocalisHost {
        var updated = record.paired(pinning: spki).withProtocolVersion(result.protocolVersion)

        // **Only when the bridge sent one.** `withBridgeID(nil)` is a real
        // write that clears the field, and an older bridge omits `bridge_id`
        // entirely (Amendment A §1.6) — so pairing with one would erase the id
        // a Bonjour advertisement had already supplied, and the next relocation
        // would fall back to matching by pin alone.
        if let bridgeID = result.bridgeID {
            updated = updated.withBridgeID(bridgeID)
        }

        // The Mac's own name for itself, now that it has said it. Not applied
        // when blank: `BridgePairing` reports a nameless bridge as an empty
        // string, and a machine listed as "" is worse than one listed by the
        // address the user typed.
        if !result.bridgeName.isEmpty {
            updated = updated.renamed(to: result.bridgeName)
        }

        return updated
    }

    // MARK: - Input

    /// Number of digits in a pairing code (contract §1).
    static let codeLength = 6

    /// The `field` values this screen puts into `LocalisError.invalidInput`.
    ///
    /// Named constants because they are matched on in `sentence(for:)`: as bare
    /// literals in two places, a rename on one side would silently fall through
    /// to `userMessage` and start rendering "Please check the fingerprint
    /// field." again, with nothing failing to say so.
    static let codeField = "code"
    static let fingerprintField = "fingerprint"


    /// The code, or a refusal before anything is sent.
    ///
    /// Checked here rather than left to the bridge because the two failures read
    /// identically to the user and only one of them is theirs to fix: a
    /// five-digit code sent to the Mac comes back 401, which says "that pairing
    /// code isn't right" — true, but it also spends one of the five attempts
    /// that invalidate the session, so three typos can kill a code that was
    /// never actually tried.
    static func validatedCode(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == codeLength,
              trimmed.allSatisfy(\.isASCII),
              trimmed.allSatisfy(\.isNumber) else {
            throw LocalisError.invalidInput(field: codeField)
        }
        return trimmed
    }

    /// SHA-256 is 32 bytes. Nothing shorter is a fingerprint of anything.
    private static let fingerprintByteCount = 32

    /// The fingerprint the user read off the Mac, or a refusal.
    ///
    /// **Length is checked, and the reason is which sentence the user gets.** A
    /// truncated paste is still valid base64, so it would sail through to the
    /// handshake and be refused there — as `certificatePinMismatch`, whose
    /// wording is "This Mac's identity has changed." That accuses the Mac of
    /// something for what is a paste that lost its tail, and it is the one
    /// sentence in this vocabulary the user must never learn to click past.
    ///
    /// Whitespace is stripped throughout rather than trimmed at the ends: the
    /// value is read off a terminal, and a line break lands in the middle of it
    /// as often as anywhere.
    static func validatedFingerprint(_ text: String) throws -> SPKIHash {
        let compact = text.filter { !$0.isWhitespace }
        guard let bytes = Data(base64Encoded: compact),
              bytes.count == fingerprintByteCount else {
            throw LocalisError.invalidInput(field: fingerprintField)
        }
        return SPKIHash(base64: compact)
    }
}
