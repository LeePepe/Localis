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
    /// Asks each machine whether it is answering (#41).
    ///
    /// Injected rather than constructed, because until this existed there was
    /// no way at all to put a `HostRuntimeState` in front of the user:
    /// the value is deliberately not persisted (Amendment C §4.2), so it cannot
    /// arrive through the repository, and it is not reachable through `DemoSeed`
    /// either — that path writes records, and this is not a record. A model that
    /// built its own transport would leave "a rejected certificate reaches the
    /// host row" checkable only against a real Mac with a real changed
    /// certificate, which is an acceptance nobody performs twice.
    private let probe: any HostProbing

    init(
        repository: any SessionRepository,
        credentials: any PinReading = HostCredentialStore(),
        probe: any HostProbing = BridgeHostProbe()
    ) {
        self.repository = repository
        self.assembly = HostAssembly(repository: repository, credentials: credentials)
        self.probe = probe
    }

    /// Reads every machine on file.
    ///
    /// Called at launch. The list it produces is the answer to "which Macs do I
    /// have", which must survive the app being killed — that is the whole of
    /// FR-026's promise from the user's side.
    ///
    /// The rows go up before anything is probed, then again once the machines
    /// have answered. Waiting for the probes would hold an entirely correct list
    /// off screen behind a network round trip per machine, and one asleep Mac
    /// would delay every other row — the same reason `probe` catches rather than
    /// throws.
    func load() async {
        do {
            // Written as a closure, not as `.map(HostRowState.init(host:))`.
            // The unapplied form names the initialiser by its full signature, so
            // it stopped resolving the moment `runtime:` was added — and the
            // failure is a type-inference error at the call site rather than
            // anything that mentions the new parameter.
            //
            // No runtime value here: nothing has been asked yet, and the
            // default `.unknown` says exactly that. `refreshReachability` is
            // what replaces it with something measured.
            let hosts = try await assembly.hosts()
            rows = hosts.map { HostRowState(host: $0) }
            loadError = nil
            await refreshReachability(of: hosts)
        } catch {
            // Never an empty list on failure. "You have no Macs" and "we could
            // not read your Macs" are different sentences, and showing the
            // first one for the second sends the user to re-pair a machine that
            // is already there.
            loadError = (error as? LocalisError)?.userMessage
                ?? "Your machines couldn't be loaded. Please try again."
            rows = []
        }
    }

    /// Asks every machine whether it is answering, and rebuilds the rows.
    ///
    /// Concurrent, because the answers are independent and one sleeping Mac must
    /// not decide how long the others take. `TaskGroup` over a local array
    /// rather than mutating `rows` as each result lands: a row set that changed
    /// N times would animate N times, and the intermediate states are not
    /// anything the user asked to see.
    private func refreshReachability(of hosts: [LocalisHost]) async {
        let probe = self.probe
        // **Only machines we could actually connect to are asked, and the reason
        // is a false sentence rather than a wasted request.** A machine that was
        // never paired has no token: `HostCredentialStore.token(for:)` returns
        // nil, `BridgeClient.request` refuses with `.unauthorized`,
        // `HostReachability(failure:)` maps that to `.unauthorized`, and its
        // wording is "This Mac **no longer** accepts this device." Said about a
        // `.discovered` machine every word of that is false — and it sends the
        // user to pair, which is the right action reached through a wrong
        // reason, so the working outcome would hide it. (Traced by `store` while
        // building its own version of this; the test below is adapted from it.)
        //
        // **Here rather than inside each probe.** `HostProbing` has two
        // implementations already and will have more; "which machines does the
        // host list ask about" is the list's policy, and a copy of it in every
        // probe is the shape that let a rejected certificate read as "check the
        // network" (#45) — two places holding an opinion that has to agree.
        // `BridgeHostProbe` keeps its own guard as well, for callers that do not
        // come through here; that one is a refusal to open a socket, this one is
        // a decision about who to ask.
        //
        // `canConnect`, not `pairingState == .paired`: it is the same question
        // plus a pin, which also covers `.paired` with the pin gone — a Keychain
        // cleared, or #30's credential-clearing path stopping half way.
        let askable = hosts.filter(\.canConnect)
        let measured = await withTaskGroup(of: (HostID, HostReachability).self) { group in
            for host in askable {
                group.addTask { (host.id, await probe.reachability(of: host)) }
            }
            var results: [HostID: HostReachability] = [:]
            for await (id, reachability) in group { results[id] = reachability }
            return results
        }

        // Rebuilt from `hosts` rather than by editing `rows`, so the row is
        // derived from the host and the answer in one place. Editing would need
        // a second copy of the `isConnectable` rule, and the two would drift.
        rows = hosts.map { host in
            HostRowState(
                host: host,
                // A machine with no answer keeps the `.unknown` default. That is
                // not a failure to report: `unreachableDetail` renders it as no
                // sentence at all, which is right — nothing was established.
                //
                // Spelled `?? .unknown` rather than mapping the optional through
                // `HostRuntimeState.init(reachability:)`: that unapplied form
                // does not name this initialiser, which takes three parameters,
                // and the error it produces talks about a generic parameter on
                // `Optional.map` rather than about the type being constructed.
                runtime: HostRuntimeState(reachability: measured[host.id] ?? .unknown)
            )
        }
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
