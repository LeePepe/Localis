import Foundation
import Testing

@testable import BridgeCore

/// The session mapping, and whether it survives the process.
///
/// **Why this is worth persisting at all.** The mapping is what lets a
/// conversation continue: the client's session id on one side, the CLI's own on
/// the other. Losing it does not break anything visibly — the next turn just
/// starts a fresh CLI conversation — which is precisely why it went unnoticed.
/// The user sees a model that has forgotten the last hour, with no error, no
/// event, and nothing they did. "Degrades silently into amnesia" is a worse
/// failure than one that says so.
@Suite("SessionStore — persistence")
struct SessionStorePersistenceTests {
    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// **The regression test**, in one assertion: a restart must not amputate
    /// the conversation.
    @Test("a mapping stored before a restart is still there after it")
    func mappingSurvivesRestart() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try SessionStore(directory: directory)
        await before.store(backendSession: "cli-1", for: "sess-1", backendID: "claude")

        let after = try SessionStore(directory: directory)
        #expect(
            await after.backendSession(for: "sess-1", backendID: "claude") == "cli-1",
            "the bridge forgot which CLI conversation this session belongs to — the next turn starts over"
        )
    }

    /// **The key is a pair, and it has to stay a pair on disk.**
    ///
    /// The same session on two backends is two conversations. A file format
    /// that flattened the key to the session id would hand codex an id only
    /// claude ever minted — and the CLI's rejection would arrive as a failed
    /// turn the user cannot act on.
    @Test("two backends on one session stay separate across a restart")
    func backendsStaySeparate() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try SessionStore(directory: directory)
        await before.store(backendSession: "claude-1", for: "sess-1", backendID: "claude")
        await before.store(backendSession: "codex-1", for: "sess-1", backendID: "codex")

        let after = try SessionStore(directory: directory)
        #expect(await after.backendSession(for: "sess-1", backendID: "claude") == "claude-1")
        #expect(await after.backendSession(for: "sess-1", backendID: "codex") == "codex-1")
    }

    /// A session never stored is absent, not some other session's id. Without
    /// this a store that returned its first entry would pass the test above.
    @Test("an unknown session is absent after a restart")
    func unknownSessionIsAbsent() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try SessionStore(directory: directory)
        await before.store(backendSession: "cli-1", for: "sess-1", backendID: "claude")

        let after = try SessionStore(directory: directory)
        #expect(await after.backendSession(for: "sess-other", backendID: "claude") == nil)
    }

    /// Re-storing replaces. This is the path a rejected `--resume` takes: the
    /// dead id is overwritten by the fresh one, and the stale value must not
    /// come back on the next restart to strand the session again.
    @Test("a replaced mapping does not revert after a restart")
    func replacementSurvives() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try SessionStore(directory: directory)
        await before.store(backendSession: "cli-dead", for: "sess-1", backendID: "claude")
        await before.store(backendSession: "cli-fresh", for: "sess-1", backendID: "claude")

        let after = try SessionStore(directory: directory)
        #expect(await after.backendSession(for: "sess-1", backendID: "claude") == "cli-fresh")
        #expect(await after.count == 1, "the superseded mapping is still on disk")
    }

    /// A first run has no file, and that is not an error.
    @Test("an empty directory yields an empty store")
    func absentFileIsNotAnError() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await SessionStore(directory: directory).isEmpty)
    }

    /// **Corruption resets, deliberately unlike `TokenStore`.**
    ///
    /// The contrast is the point, and it is not an inconsistency. A corrupt
    /// grant file is *authority*: replacing it with an empty one revokes every
    /// pairing on the machine, so it must be reported and never repaired. A
    /// corrupt session file costs one fresh CLI conversation per session — the
    /// exact thing that happens today on every restart, and which the code
    /// already calls recoverable.
    ///
    /// Refusing to start over it would trade a recoverable degradation for a
    /// bridge that will not come up at all. That is the worse outcome, and the
    /// user cannot fix either one from a phone.
    @Test("an unreadable session file resets rather than refusing to start", arguments: [
        "this is not json",
        "{\"unexpected\": \"shape\"}",
        "[{\"nope\": 1}]",
    ])
    func corruptFileResets(contents: String) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try contents.write(
            to: directory.appendingPathComponent(SessionStore.fileName),
            atomically: true,
            encoding: .utf8
        )

        let store = try SessionStore(directory: directory)
        #expect(await store.isEmpty)

        // And it must be usable afterwards, not wedged: a store that reset but
        // then refused to write would lose every session from here on.
        await store.store(backendSession: "cli-1", for: "sess-1", backendID: "claude")
        #expect(try await SessionStore(directory: directory).backendSession(for: "sess-1", backendID: "claude") == "cli-1")
    }

    /// The file names conversations on the user's machine, so it gets the same
    /// owner-only treatment as the credentials beside it (constitution §I).
    @Test("the session file is not readable by anyone but the owner")
    func fileIsOwnerOnly() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SessionStore(directory: directory)
        await store.store(backendSession: "cli-1", for: "sess-1", backendID: "claude")

        let path = directory.appendingPathComponent(SessionStore.fileName).path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue

        #expect(permissions & 0o077 == 0, "session file is mode \(String(permissions, radix: 8))")
    }

    /// The in-memory store stays available, and must not quietly write
    /// anywhere. `init()` is what the tests and a no-persistence bridge use.
    @Test("an ephemeral store writes nothing")
    func ephemeralStoreWritesNothing() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore()
        await store.store(backendSession: "cli-1", for: "sess-1", backendID: "claude")

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(await store.backendSession(for: "sess-1", backendID: "claude") == "cli-1")
    }
}
