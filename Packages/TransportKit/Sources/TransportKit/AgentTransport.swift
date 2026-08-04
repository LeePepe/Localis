import Foundation
import LocalisModels

/// A turn in progress: the id needed to resume or cancel it, and its events.
///
/// The id is a property rather than the first event because it arrives in the
/// response header, before any body (contract §3.3). A turn whose id can only be
/// learned by reading the stream is unresumable in exactly the case that
/// matters — the connection dying early — and a turn the Mac is still generating
/// then looks identical to one that never started.
///
/// Top-level rather than nested in a client, because the seam is what every
/// layer above names; a type spelled `SomeClient.TurnStream` would make the
/// protocol read as if it belonged to one implementation.
public struct TurnStream: Sendable {
    /// The bridge's id for this turn, when it sent one.
    ///
    /// Optional because a bridge older than the resume contract omits the
    /// header. Nil means "cannot be resumed", which callers must handle as a
    /// real case rather than assume away.
    public let turnID: String?
    public let events: AsyncThrowingStream<SequencedEvent, Error>

    public init(turnID: String?, events: AsyncThrowingStream<SequencedEvent, Error>) {
        self.turnID = turnID
        self.events = events
    }
}

/// Wire-level connection to a local agent.
///
/// The single seam between Localis and any agent backend. `ChatService` depends
/// on this protocol, never on a concrete transport — which is what lets tests
/// run without a live agent. Backends are data, so one conformer serves every
/// backend the bridge advertises — there is no per-backend implementation.
///
/// Events are `SequencedEvent`, not a reduced `.chunk`/`.completed`/`.failed`
/// triple. The narrower shape was here first and is tempting to restore, but it
/// cannot express two things the contract requires: a failure's progress
/// (`failed_at_ms`, `tool_calls_completed` — §3.1(d), which forbids a bare
/// "Error"), and a `seq` to dedupe a replay against (§3.3). Both are parsed off
/// the wire already; the narrow seam was the only thing discarding them.
public protocol AgentTransport: Sendable {
    /// Streams the agent's reply.
    ///
    /// Implementations must map every wire failure into `LocalisError` before
    /// it escapes — callers never see `URLError` or decoding errors raw.
    ///
    /// - Throws: before the stream begins, for a refused or unreadable
    ///   response. Failures *during* the stream surface through it instead, so
    ///   text the user already saw is kept (FR-019).
    func send(_ request: TurnRequest) async throws -> TurnStream

    /// Cheap liveness probe used by the backend-list UI.
    ///
    /// Answers *why* a host is unusable, not only *whether* (#40). A `Bool` has
    /// one bit for four situations that call for four different user actions,
    /// and a screen given only that bit can say nothing more useful than
    /// "unavailable" — including when the honest answer is "this Mac's identity
    /// has changed", which no amount of waiting will clear.
    ///
    /// **Non-throwing on purpose, and it must stay that way.** This runs while
    /// the host list is being drawn. A throwing probe turns one unreachable Mac
    /// into an error the user has to dismiss before seeing any of their hosts,
    /// including the reachable ones. `.unreachable(reason:)` is the failure
    /// channel; there is no second one.
    func probe(_ backend: AgentBackend) async -> HostReachability
}
