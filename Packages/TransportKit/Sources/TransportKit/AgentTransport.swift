import Foundation
import LocalisModels

/// One unit of streamed output from an agent backend.
public enum TransportEvent: Equatable, Sendable {
    /// A chunk of assistant text.
    case chunk(String)
    /// The backend signalled the turn is finished.
    case completed
    /// The backend reported a failure mid-stream.
    case failed(LocalisError)
}

/// A request to send to an agent backend.
public struct TransportRequest: Equatable, Sendable {
    public let backend: AgentBackend
    public let prompt: String
    /// Prior turns to replay as context, oldest first.
    public let history: [Message]

    public init(backend: AgentBackend, prompt: String, history: [Message] = []) {
        self.backend = backend
        self.prompt = prompt
        self.history = history
    }
}

/// Wire-level connection to a local agent.
///
/// The single seam between Localis and any agent backend. `ChatService` depends
/// on this protocol, never on a concrete transport — which is what lets tests
/// run without a live agent. Backends are data, so one conformer serves every
/// backend the bridge advertises — there is no per-backend implementation.
public protocol AgentTransport: Sendable {
    /// Streams the agent's reply as a sequence of events.
    ///
    /// Implementations must map every wire failure into `LocalisError` before
    /// it escapes — callers never see `URLError` or decoding errors raw.
    func send(_ request: TransportRequest) async throws -> AsyncThrowingStream<TransportEvent, Error>

    /// Cheap liveness probe used by the backend-list UI.
    func probe(_ backend: AgentBackend) async -> Bool
}
