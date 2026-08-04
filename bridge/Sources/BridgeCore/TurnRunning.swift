import Foundation

/// One turn's request, as the handler understood it (contract §3).
public struct TurnRequest: Sendable {
    /// The backend id from the body's `model` field.
    public let backendID: String
    /// The conversation. The last user message is the prompt; the rest is what
    /// the client believes the history to be.
    public let messages: [Message]
    /// The contract's session id, from `x-localis-session-id`. Distinct from
    /// the CLI's own session id, which the bridge stores against it.
    public let sessionID: String?
    public let workspace: String?

    public struct Message: Sendable, Hashable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public init(
        backendID: String,
        messages: [Message],
        sessionID: String? = nil,
        workspace: String? = nil
    ) {
        self.backendID = backendID
        self.messages = messages
        self.sessionID = sessionID
        self.workspace = workspace
    }

    /// The text to send. The last user message, not the concatenation of all of
    /// them — the CLI keeps its own history under `--resume`, and replaying the
    /// transcript would make it answer the whole conversation again.
    public var prompt: String? {
        messages.last { $0.role == "user" }?.content
    }

    /// Parses the body the iOS client sends.
    ///
    /// Returns nil rather than throwing on anything unusable, because every
    /// failure here has the same answer: the request was malformed. Validating
    /// at the boundary means nothing downstream has to wonder whether `model`
    /// is a string.
    public static func decode(
        body: [UInt8],
        sessionID: String?,
        workspace: String?
    ) -> TurnRequest? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(body)),
            let frame = object as? [String: Any],
            let model = frame["model"] as? String,
            !model.isEmpty,
            let rawMessages = frame["messages"] as? [[String: Any]]
        else {
            return nil
        }

        let messages = rawMessages.compactMap { entry -> Message? in
            guard
                let role = entry["role"] as? String,
                let content = entry["content"] as? String
            else {
                return nil
            }
            return Message(role: role, content: content)
        }

        // A turn with no readable message has nothing to ask. Better refused
        // here than sent to the CLI as an empty prompt, which it answers.
        guard !messages.isEmpty else { return nil }

        return TurnRequest(
            backendID: model,
            messages: messages,
            sessionID: sessionID,
            workspace: workspace
        )
    }
}

/// What a turn produced, before the server stamps sequence numbers on it.
public enum TurnOutput: Sendable {
    /// An event for the client.
    case event(BridgeEvent)
    /// The backend's own session id, to store against the contract session so
    /// the next turn can continue the same conversation.
    case backendSession(String)
}

/// Runs a turn on some backend.
///
/// **The seam that keeps constitution IV true on this side.** `BridgeCore`
/// knows there is a thing that turns a prompt into a stream of events; it does
/// not know that `claude` exists, what arguments it takes, or that a process is
/// involved at all. A sixth backend is a sixth conformance.
public protocol TurnRunning: Sendable {
    /// Which backend this runs. Matched against the request's `model`.
    var backendID: String { get }

    /// Runs one turn.
    ///
    /// - Parameter resuming: the backend's own session id from a previous turn,
    ///   or nil to start fresh.
    func run(
        prompt: String,
        resuming: String?,
        workspace: String?
    ) -> AsyncThrowingStream<TurnOutput, any Error>
}
