import Foundation

/// Maps the contract's session ids onto the backends' own.
///
/// The two are deliberately different things. The client mints a session id and
/// keeps it forever; `claude` mints its own on the first turn and expects it
/// back under `--resume`. Storing the pair here is what makes a conversation
/// continue across turns without either side learning about the other's
/// identifier scheme.
///
/// **The mapping outlives the process.** It used to live in memory only, and the
/// cost of that was easy to under-read — the old comment here called it
/// "recoverable, and honest". It is recoverable; it is not visible. A restart
/// fails nothing: the next turn simply starts a fresh CLI conversation. Nothing
/// errors, nothing is logged, and the user sees a model that has forgotten the
/// last hour with no event to point at and nothing they did to cause it. A
/// silent degradation into amnesia is worse than a loud failure, because it is
/// the one the user blames themselves for.
public actor SessionStore {
    /// Keyed by (contract session, backend), because the same session on two
    /// backends is two conversations. Keying on the session alone would hand
    /// codex a session id that only claude ever minted.
    private struct Key: Hashable {
        let sessionID: String
        let backendID: String
    }

    /// One mapping, as stored.
    ///
    /// Explicit fields rather than a dictionary keyed by a joined string: a
    /// composite key flattened into `"\(session):\(backend)"` becomes ambiguous
    /// the moment either part can contain the separator, and both come from
    /// outside this process. Keeping the parts apart on disk means the file
    /// format cannot introduce a collision the in-memory key does not have.
    private struct Entry: Sendable, Hashable, Codable {
        let sessionID: String
        let backendID: String
        let backendSession: String
    }

    /// Beside `cert.pem`, `key.pem` and `grants.json`, in the same owner-only
    /// directory (constitution §I).
    public static let fileName = "sessions.json"

    private var backendSessions: [Key: String] = [:]

    /// Where mappings are written, or nil for a store that keeps nothing.
    private let fileURL: URL?

    /// An in-memory store that writes nothing.
    public init() {
        self.fileURL = nil
    }

    /// Loads the mappings stored in `directory`, if any.
    ///
    /// **An unreadable file resets rather than throwing** — deliberately the
    /// opposite of ``TokenStore``, and the contrast is the argument rather than
    /// an inconsistency. A corrupt grant file is *authority*: discarding it
    /// revokes every pairing on the machine, so it must be reported and never
    /// repaired. A corrupt session file costs one fresh CLI conversation per
    /// session — precisely what every restart used to cost. Refusing to start
    /// would trade a recoverable degradation for a bridge that does not come up
    /// at all, and the user can fix neither from a phone.
    ///
    /// - Throws: nothing today. `throws` is kept so that a future format needing
    ///   a real failure can add one without changing every call site.
    public init(directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        self.fileURL = url

        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }

        backendSessions = Dictionary(
            entries.map { (Key(sessionID: $0.sessionID, backendID: $0.backendID), $0.backendSession) },
            uniquingKeysWith: { _, last in last }
        )
    }

    public func backendSession(for sessionID: String, backendID: String) -> String? {
        backendSessions[Key(sessionID: sessionID, backendID: backendID)]
    }

    public func store(backendSession: String, for sessionID: String, backendID: String) {
        backendSessions[Key(sessionID: sessionID, backendID: backendID)] = backendSession
        persist()
    }

    /// How many mappings are held.
    public var count: Int { backendSessions.count }

    /// Whether this bridge holds no session mappings.
    public var isEmpty: Bool { backendSessions.isEmpty }

    /// Writes the current mappings, owner-only.
    ///
    /// A write failure is reported and not thrown: the turn it belongs to is
    /// already running, and failing it would break a working conversation in
    /// order to report that a *future* restart will forget it. The cost of the
    /// failure is the old behaviour, said out loud rather than silently.
    private func persist() {
        guard let fileURL else { return }

        let entries = backendSessions
            .map { Entry(sessionID: $0.key.sessionID, backendID: $0.key.backendID, backendSession: $0.value) }
            // Sorted so the file is stable across writes. A dictionary's order
            // is not, so an unsorted dump rewrites the file differently every
            // turn even when nothing changed — which makes "did this actually
            // get written" unanswerable by looking at it.
            .sorted { ($0.sessionID, $0.backendID) < ($1.sessionID, $1.backendID) }

        guard let data = try? JSONEncoder().encode(entries) else {
            Self.warn("could not encode session mappings; they will not survive a restart")
            return
        }

        // Mode set in the same call that creates the file, never chmod'd after
        // — the same treatment `grants.json` gets. `createFile` replaces an
        // existing file's contents but leaves its permissions alone, so the mode
        // is re-asserted below.
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            Self.warn("could not write session mappings; they will not survive a restart")
            return
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.warn("could not restrict permissions on the session file")
        }
    }

    /// Reports a persistence problem on stderr.
    ///
    /// Never includes a session id, a backend session id, or the file's
    /// contents — constitution §I. Those name conversations on the user's
    /// machine.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("localis-bridge: \(message)\n".utf8))
    }
}
