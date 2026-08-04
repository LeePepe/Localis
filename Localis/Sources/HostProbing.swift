import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// Asks one machine whether it is answering right now.
///
/// **Why the app layer needs its own protocol when `AgentTransport` exists.**
/// `AgentTransport.probe` takes an `AgentBackend`, because everything below this
/// line is scoped to one agent on one machine. The host list has no backend in
/// hand — it is asking about the *machine*, before any conversation picks an
/// agent — so a host-level question needs a host-level shape. `BridgeClient`
/// answers it with `models()`, which is already a statement about the host: it
/// is the one request that has to reach the machine before any backend can be
/// named.
///
/// It exists as a protocol for the same reason `PinReading` does: the real
/// implementation opens a TLS connection to a machine that is not there in CI,
/// and a suite whose failures depend on the network teaches people to ignore it.
protocol HostProbing: Sendable {
    /// Whether `host` is answering, and if not, why.
    ///
    /// **Never throws, and this is a requirement rather than a convenience.**
    /// The host list probes every machine; one that throws would turn a single
    /// sleeping Mac into an error the user has to dismiss before seeing any of
    /// their machines (FR-034). The same rule holds one layer down, and
    /// `AgentTransport.probe` documents it there.
    func reachability(of host: LocalisHost) async -> HostReachability
}

/// The real probe: one `/v1/models` round trip per machine, over its own pinned
/// connection.
///
/// **Two transports are live in this app right now, and they are not the same
/// one.** The host list probes through a real `BridgeClient` — a real socket,
/// real TLS, this machine's own pin. Conversations still send through
/// `EchoTransport` (`SessionDetailView.swift:307`), which reaches no machine at
/// all. That is not a design; it is milestone B in progress. When that line
/// becomes a real transport too, this paragraph and the split it describes both
/// disappear.
///
/// Recorded here rather than left to be discovered because the two are easy to
/// mistake for one system: a host row that says a machine is reachable, above a
/// conversation whose replies never left the phone, is a screen that looks
/// entirely coherent.
struct BridgeHostProbe: HostProbing {
    private let credentials: HostCredentialStore

    init(credentials: HostCredentialStore = HostCredentialStore()) {
        self.credentials = credentials
    }

    func reachability(of host: LocalisHost) async -> HostReachability {
        do {
            let client = try BridgeClient(
                host: host.id,
                endpoint: host.endpoint,
                credentials: credentials
            )
            _ = try await client.models()
            return .reachable
        } catch let error as LocalisError {
            // The mapping lives in `HostReachability(failure:)` so this file has
            // no opinion about which failure means what — one table, used by
            // `BridgeClient.probe` as well.
            return HostReachability(failure: error)
        } catch {
            // `models()` maps everything into `LocalisError` before it escapes,
            // so this is unreachable today. Kept rather than force-unwrapped:
            // the alternative to a wrong-but-harmless `.offline` here is a
            // crash in the host list, and `.offline` is the reason whose advice
            // costs nothing when it is wrong.
            return .unreachable(reason: .offline)
        }
    }
}
