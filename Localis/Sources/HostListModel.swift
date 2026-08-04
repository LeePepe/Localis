import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// The machines the user has added, loaded from disk.
///
/// **What was missing before this existed.** `Session.hostID` named a table that
/// did not exist; then `StoredHost` arrived and nothing wrote to it or read from
/// it. Every part was correct and the app still could not remember a single Mac
/// across a relaunch — a package can have all its public symbols referenced and
/// still not be able to do the one thing it exists for. This type is the join,
/// and `HostRecoveryTests` is the only place that failure is visible.
///
/// `@MainActor` for the same reason `SessionListModel` is: it publishes to
/// SwiftUI and nothing else. Repository work is awaited off this actor.
@MainActor
@Observable
final class HostListModel {
    private(set) var rows: [HostRowState] = []
    private(set) var loadError: String?

    private let repository: any SessionRepository
    /// Reads go through the join, not the store.
    ///
    /// **This is the difference between a list and a usable list.** The store
    /// has no pin column, so a host read straight from it always has
    /// `canConnect == false` — the screen would show every machine as
    /// unconnectable forever, including the ones the user paired. Writes still
    /// go to the repository directly: adding a machine creates a record, and
    /// records are the store's business.
    private let assembly: HostAssembly
    /// Asks each machine whether it is answering. See `HostProbing` for why the
    /// app layer has its own shape for this, and for the two-transport split
    /// that is live while milestone B is in progress.
    private let probing: any HostProbing
    /// The machines behind the rows, kept so a probe result can be re-projected.
    ///
    /// `HostRowState` is a projection — strings and booleans — and cannot be
    /// reversed into the `LocalisHost` it came from. Applying a probe result
    /// means building the row again from both halves, so the host half has to
    /// still be here. Keyed by id rather than held as a parallel array: rows can
    /// be removed while a probe is in flight, and an index would then name a
    /// different machine.
    private var hostsByID: [HostID: LocalisHost] = [:]
    /// The in-flight probe pass, so a test can wait for it rather than race it.
    ///
    /// Deliberately not awaited by `load()`: rows must reach the screen before
    /// any machine answers, or the list stays empty for as long as the slowest
    /// unreachable Mac takes to time out — and an empty list reads as "you have
    /// no machines".
    private var probeTask: Task<Void, Never>?

    init(
        repository: any SessionRepository,
        credentials: any PinReading = HostCredentialStore(),
        probing: any HostProbing = BridgeHostProbe()
    ) {
        self.repository = repository
        self.assembly = HostAssembly(repository: repository, credentials: credentials)
        self.probing = probing
    }

    /// Reads every machine on file.
    ///
    /// Called at launch. The list it produces is the answer to "which Macs do I
    /// have", which must survive the app being killed — that is the whole of
    /// FR-026's promise from the user's side.
    func load() async {
        do {
            // Written as a closure, not as `.map(HostRowState.init(host:))`.
            // The unapplied form names the initialiser by its full signature, so
            // it stopped resolving the moment `runtime:` was added — and the
            // failure is a type-inference error at the call site rather than
            // anything that mentions the new parameter.
            //
            // No runtime value is passed here: nothing has probed these machines
            // *yet*, and the default says so. `probe` supplies the live one as a
            // second pass — for the paired machines. A `.discovered` machine is
            // never asked and keeps this `.unknown` for good, which is correct
            // rather than a gap: nothing has been established about whether it
            // answers, and `.unknown` is exactly that claim. See `probe`.
            let hosts = try await assembly.hosts()
            rows = hosts.map { HostRowState(host: $0) }
            hostsByID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            loadError = nil
            probe(hosts)
        } catch {
            // Never an empty list on failure. "You have no Macs" and "we could
            // not read your Macs" are different sentences, and showing the
            // first one for the second sends the user to re-pair a machine that
            // is already there.
            loadError = (error as? LocalisError)?.userMessage
                ?? "Your machines couldn't be loaded. Please try again."
            rows = []
            // Cleared with the rows, not left behind. A stale entry here would
            // let a probe from the previous pass land on a list that has since
            // failed to load — `apply` looks rows up by id, and the id would
            // still match.
            hostsByID = [:]
            probeTask?.cancel()
            probeTask = nil
        }
    }

    /// Asks each paired machine whether it is answering, and updates its row.
    ///
    /// **Only `.paired` machines are asked, and the reason is not efficiency.**
    /// A machine that was never paired has no token in the Keychain, and
    /// `BridgeClient` refuses an unauthenticated request with
    /// `LocalisError.unauthorized` — which `HostReachability(failure:)` maps to
    /// `.unauthorized`, whose sentence is "This Mac no longer accepts this
    /// device." Measured, not inferred: `HostCredentialStore.token(for:)`
    /// returns nil rather than throwing, so the refusal happens at
    /// `BridgeClient.request` and arrives here indistinguishable from a machine
    /// that revoked us.
    ///
    /// That sentence is false about a `.discovered` machine — it never accepted
    /// this device — and it points the user at the wrong thing while sounding
    /// specific. Its row already says "Not paired", which is both true and the
    /// action to take, so nothing is being hidden by staying quiet here.
    ///
    /// The same `.paired` gate guards the Keychain read in `HostAssembly.joined`,
    /// for a related reason: state below `.paired` means there is no credential
    /// to use, and reaching for one anyway produces a confident wrong answer.
    private func probe(_ hosts: [LocalisHost]) {
        probeTask?.cancel()
        let pairedHosts = hosts.filter { $0.pairingState == .paired }
        guard !pairedHosts.isEmpty else {
            probeTask = nil
            return
        }

        probeTask = Task { [probing] in
            // A task group, so one machine that takes the full timeout does not
            // hold up the answer from a machine next to it (FR-034). Each result
            // is applied as it lands rather than at the end, for the same reason
            // rows are published before any probe finishes.
            await withTaskGroup(of: (HostID, HostReachability).self) { group in
                for host in pairedHosts {
                    group.addTask { (host.id, await probing.reachability(of: host)) }
                }
                for await (id, reachability) in group {
                    self.apply(reachability, to: id)
                }
            }
        }
    }

    /// Writes one probe result into its row.
    ///
    /// Rebuilds the row from the same initialiser rather than assigning to
    /// `runtime`: `isConnectable` is derived from both halves, and setting one
    /// field would leave a row claiming it can connect to a machine that just
    /// refused. `HostRowState` is a value, so this is a replacement, not a
    /// mutation.
    ///
    /// A row that has since disappeared — the user removed the machine, or the
    /// list failed to reload, while a probe was in flight — is simply not found,
    /// and the answer is dropped.
    private func apply(_ reachability: HostReachability, to id: HostID) {
        guard let host = hostsByID[id],
              let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index] = HostRowState(
            host: host,
            runtime: HostRuntimeState(reachability: reachability)
        )
    }

    /// Waits for the current probe pass. Test support: the probes run in a
    /// detached task, and an assertion made straight after `load()` would race
    /// them — which is exactly the window `rowsAppearBeforeProbesComplete` is
    /// about, so it must be possible to be on either side of it deliberately.
    func probesFinished() async {
        await probeTask?.value
    }

    /// Adds a machine from an address the user typed (FR-001).
    ///
    /// The path Bonjour cannot serve: Tailscale, a VPN, and most guest networks
    /// carry no multicast. It goes through the same `DiscoveredHost` validation
    /// and the same `LocalisHost(adopting:)` rule as a broadcast sighting —
    /// manual entry is not a privileged path, or typing an address would be a
    /// way around pinning.
    ///
    /// - Throws: `LocalisError.invalidInput(field: "endpoint")` for an address
    ///   that is not usable, before anything is written.
    func addHost(typedAddress text: String) async throws {
        let discovered = try DiscoveredHost(manualEndpoint: text)
        // `.discovered`, no pin, fresh local id — see `LocalisHost(adopting:)`.
        // The host is stored *before* it is paired on purpose: a machine the
        // user added and then quit on should still be there next launch.
        try await repository.save(LocalisHost(adopting: discovered))
        await load()
    }
}

/// One machine, projected for display.
///
/// A value type carrying strings and booleans, so the view has nothing to decide
/// and nothing to reach back through.
///
/// **Why it lives in the app target is an open question, not a settled one.**
/// The comment that used to stand here gave a reason — that `LocalisUI` cannot
/// depend on `LocalisModels`, the same way `SessionRowState` is handed values
/// rather than a `Session` — and every part of it is false. Checked 2026-08-04:
/// `LocalisUI/Package.swift` lists `LocalisModels` as a dependency and six files
/// under `Packages/LocalisUI/Sources` import it, `SessionRowState` among them;
/// and `SessionRowState.make(from:backends:)` takes a `Session` directly, which
/// is the opposite of what was claimed about it.
///
/// Left in place rather than moved. Moving it is a cross-package change, and
/// making it on the strength of a reason nobody has verified would replace one
/// unchecked justification with another. This note exists so the next reader
/// finds "undecided" rather than an unexplained placement — the reasonable
/// response to which is to supply a reason, which is how the false one got here.
struct HostRowState: Identifiable, Equatable, Sendable {
    let id: HostID
    let title: String
    /// Where it answers, for the subtitle — the one thing that distinguishes two
    /// machines the user gave the same name.
    let subtitle: String
    /// The **pairing relationship** — durable, and only a person can change it.
    /// Never a probe result; see `unreachableDetail` for that half, and FR-061
    /// for why the two must not be merged into one line.
    let status: String
    /// Whether the app may open a connection. Derived from `canConnect`, which
    /// requires paired **and** pinned: a row that offered to connect on the
    /// strength of the state alone would connect to an unpinned machine.
    ///
    /// Now also false while the last probe says the host is unreachable. The two
    /// conditions are independent — a stored pairing says nothing about whether
    /// the machine answered a moment ago.
    let isConnectable: Bool
    /// What the last probe established. Not persisted, and `.unknown` until one
    /// has actually run (Amendment C §4.2).
    let runtime: HostRuntimeState

    /// Why this machine is unusable right now, or `nil` when nothing is known to
    /// be wrong (FR-060).
    ///
    /// **`nil` covers two different situations on purpose.** A reachable host
    /// and a never-probed one both produce no sentence, because in neither case
    /// is there a failure to report. Rendering `.unknown` as a problem would put
    /// "isn't answering" under every machine at launch — a claim no probe backs,
    /// and one the user would have to disprove.
    var unreachableDetail: String? {
        switch runtime.reachability {
        case .unreachable(let reason): reason.userMessage
        case .reachable, .unknown: nil
        }
    }

    /// Whether the last probe established that this host is not usable.
    ///
    /// Separate from `unreachableDetail != nil` in intent only: this one is for
    /// deciding, that one is for showing.
    var isUnreachable: Bool {
        if case .unreachable = runtime.reachability { return true }
        return false
    }

    /// - Parameter runtime: defaults to `.unknown` reachability, never
    ///   `.reachable`. Every existing call site builds rows straight off disk
    ///   with no probe behind them (#41 supplies the live one), and a default of
    ///   `.reachable` would have all of them assert something nothing measured.
    init(host: LocalisHost, runtime: HostRuntimeState = HostRuntimeState()) {
        id = host.id
        title = host.displayName
        subtitle = host.endpoint.displayText
        status = Self.statusText(for: host.pairingState)
        self.runtime = runtime
        // Both halves must hold. `canConnect` answers "is this pairing good",
        // reachability answers "did it answer" — a machine that just refused our
        // certificate satisfies the first and fails the second.
        if case .unreachable = runtime.reachability {
            isConnectable = false
        } else {
            isConnectable = host.canConnect
        }
    }

    /// Wording per pairing state.
    ///
    /// Exhaustive with no `default`, deliberately: a new state must come here
    /// and be given words, rather than silently inheriting whatever the last
    /// case said.
    ///
    /// Not private, so a test can assert *which state* a row reports without
    /// restating the sentence. Pinning FR-061 to the literal text would mean a
    /// copy-edit breaks a rule about state selection, and whoever fixed it would
    /// paste the new wording rather than ask what the test was for.
    static func statusText(for state: HostPairingState) -> String {
        switch state {
        case .discovered: "Not paired"
        case .pairing: "Pairing…"
        case .paired: "Paired"
        case .revoked: "Unpaired"
        // Named as a problem, not as an error code. This is the state the user
        // must act on, and it must never read as something a retry would fix
        // (constitution V allows no override).
        //
        // **FR-061: this is what the row shows — not
        // `HostUnreachableReason.certificateRejected`.** The names are close
        // enough that merging them is the next reader's reasonable move, and the
        // reason not to is that they are cause and effect rather than synonyms.
        // `certificateRejected` is the outcome of one connection attempt and is
        // never persisted, so the next probe — the Mac simply being switched
        // off — would replace it with "offline", and the fact that this
        // machine's identity changed would vanish from the screen while the
        // pairing stayed compromised. This state is durable and only a person
        // can leave it.
        case .certificateChanged: "Certificate changed"
        }
    }
}
