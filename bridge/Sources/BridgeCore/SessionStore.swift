import Foundation

/// Maps the contract's session ids onto the backends' own.
///
/// The two are deliberately different things. The client mints a session id and
/// keeps it forever; `claude` mints its own on the first turn and expects it
/// back under `--resume`. Storing the pair here is what makes a conversation
/// continue across turns without either side learning about the other's
/// identifier scheme.
///
/// In memory only, for now. A bridge restart loses the mapping, which surfaces
/// as the next turn starting a fresh CLI conversation — recoverable, and
/// honest, where a wrong id would make the CLI reject the turn outright.
public actor SessionStore {
    /// Keyed by (contract session, backend), because the same session on two
    /// backends is two conversations. Keying on the session alone would hand
    /// codex a session id that only claude ever minted.
    private struct Key: Hashable {
        let sessionID: String
        let backendID: String
    }

    private var backendSessions: [Key: String] = [:]

    public init() {}

    public func backendSession(for sessionID: String, backendID: String) -> String? {
        backendSessions[Key(sessionID: sessionID, backendID: backendID)]
    }

    public func store(backendSession: String, for sessionID: String, backendID: String) {
        backendSessions[Key(sessionID: sessionID, backendID: backendID)] = backendSession
    }
}
