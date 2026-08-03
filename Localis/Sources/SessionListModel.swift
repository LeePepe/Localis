import Foundation
import LocalisModels
import LocalisUI
import SessionStore

/// Loads the session list and projects it for `LocalisUI`.
///
/// This is the component the assembly layer was missing: something that holds a
/// *concrete* repository and hands views nothing but value types. `LocalisUI`
/// cannot depend on `SessionStore` (its `depends_on` does not name it), so the
/// join has to happen here, above both.
///
/// `@MainActor` because it only ever publishes to SwiftUI. The repository work
/// itself is `await`ed off this actor — reads must not block the main thread.
@MainActor
@Observable
final class SessionListModel {
    private(set) var rows: [SessionRowState] = []
    private(set) var loadError: String?

    private let repository: any SessionRepository

    init(repository: any SessionRepository) {
        self.repository = repository
    }

    /// Loads every session and the backends of the hosts they name.
    ///
    /// There is deliberately no "all backends" call to make this shorter. A
    /// backend id is unique only *within* one machine (FR-029), so a flat list
    /// across hosts would silently merge two different agents that both call
    /// themselves `claude`. Asking per host is what keeps a row's name the name
    /// of the thing that actually answered.
    func load() async {
        do {
            let sessions = try await repository.allSessions()
            let backends = try await backends(for: sessions)
            rows = sessions.map { SessionRowState.make(from: $0, backends: backends) }
            loadError = nil
        } catch {
            // Shown, never swallowed: an unreadable store is a real condition
            // the user needs to see, and an empty list would read as "no
            // sessions yet" — a different, wrong statement.
            loadError = (error as? LocalisError)?.userMessage ?? "Please try again."
        }
    }

    /// The backends of every host the given sessions name, keyed by `BackendRef`.
    ///
    /// The key matters as much as the query. An earlier version asked per host —
    /// correctly — and then flattened the answers into one `[AgentBackend]`,
    /// which threw away the very thing the per-host query had just established.
    /// Two machines both advertising `claude` came back as two entries the
    /// projection could no longer tell apart, and the list showed one session
    /// wearing the other machine's backend name. Tagging each backend with the
    /// host that answered keeps that distinction all the way to the row.
    ///
    /// Orphaned sessions name a host that is no longer paired; the store answers
    /// with none and the row falls back to "Unknown agent" rather than vanishing
    /// (FR-036).
    private func backends(for sessions: [Session]) async throws -> [BackendRef: AgentBackend] {
        var seen: Set<HostID> = []
        var collected: [BackendRef: AgentBackend] = [:]
        for hostID in sessions.map(\.hostID) where seen.insert(hostID).inserted {
            for backend in try await repository.backends(ofHost: hostID) {
                collected[backend.ref(on: hostID)] = backend
            }
        }
        return collected
    }
}
