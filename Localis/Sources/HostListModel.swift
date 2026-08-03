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

    init(repository: any SessionRepository) {
        self.repository = repository
    }

    /// Reads every machine on file.
    ///
    /// Called at launch. The list it produces is the answer to "which Macs do I
    /// have", which must survive the app being killed — that is the whole of
    /// FR-026's promise from the user's side.
    func load() async {
        do {
            rows = try await repository.hosts().map(HostRowState.init(host:))
            loadError = nil
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
/// and nothing to reach back through. It lives in the app target rather than in
/// `LocalisUI` because `LocalisUI` cannot depend on `LocalisModels` for this —
/// the same reason `SessionRowState` is handed values rather than a `Session`.
struct HostRowState: Identifiable, Equatable, Sendable {
    let id: HostID
    let title: String
    /// Where it answers, for the subtitle — the one thing that distinguishes two
    /// machines the user gave the same name.
    let subtitle: String
    let status: String
    /// Whether the app may open a connection. Derived from `canConnect`, which
    /// requires paired **and** pinned: a row that offered to connect on the
    /// strength of the state alone would connect to an unpinned machine.
    let isConnectable: Bool

    init(host: LocalisHost) {
        id = host.id
        title = host.displayName
        subtitle = host.endpoint.displayText
        status = Self.status(of: host.pairingState)
        isConnectable = host.canConnect
    }

    /// Wording per state.
    ///
    /// Exhaustive with no `default`, deliberately: a new state must come here
    /// and be given words, rather than silently inheriting whatever the last
    /// case said.
    private static func status(of state: HostPairingState) -> String {
        switch state {
        case .discovered: "Not paired"
        case .pairing: "Pairing…"
        case .paired: "Paired"
        case .revoked: "Unpaired"
        // Named as a problem, not as an error code. This is the state the user
        // must act on, and it must never read as something a retry would fix
        // (constitution V allows no override).
        case .certificateChanged: "Certificate changed"
        }
    }
}
