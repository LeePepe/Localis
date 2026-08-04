import BridgeAdapters
import BridgeCore
import Foundation

/// The bridge process.
///
/// Starts the listener, prints the pairing code, and stays up. Everything it
/// says to the operator goes to stdout here — this is the only place in the
/// program that prints, and it prints no token, no message body and no working
/// directory (constitution §I).
///
/// Named `Bridge.swift` rather than `main.swift` on purpose: a file called
/// `main.swift` is a top-level-code file, where `@main` is rejected.
@main
struct Bridge {
    static func main() async {
        do {
            try await run()
        } catch {
            // A fixed line, not the error's description: a start-up failure
            // routinely quotes a path, and stderr here may be a shared terminal
            // or a log.
            FileHandle.standardError.write(Data("localis-bridge: failed to start\n".utf8))
            // …but "failed to start" alone leaves the operator with nothing to
            // do. A few failures have a remedy that can be named without
            // naming anything sensitive, so they get one line more. The text is
            // written here rather than taken from the error for the same reason
            // the line above is fixed.
            if let remedy = Self.remedy(for: error) {
                FileHandle.standardError.write(Data("localis-bridge: \(remedy)\n".utf8))
            }
            exit(1)
        }
    }

    /// What the operator can do about a start-up failure, when that is sayable.
    ///
    /// nil for everything else — a guess would be worse than silence, and the
    /// fixed line above has already said the bridge is not running.
    private static func remedy(for error: any Error) -> String? {
        switch error {
        case TokenStore.Failure.unreadableGrants:
            // Deliberately not repaired on the bridge's own initiative:
            // replacing the file would unpair every device on this Mac
            // silently. Saying so turns a mystery into an instruction.
            return "the pairing record is damaged; delete it and pair this Mac again"
        default:
            return nil
        }
    }

    private static func run() async throws {
        let port = environmentPort ?? 8765
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".localis", isDirectory: true)

        // The same key across restarts: the phone pinned it, so regenerating
        // would silently break every device that had already paired.
        let identity = try BridgeIdentity.loadOrCreate(in: home)

        // Separate from the pin on purpose — see `BridgeInstanceID`. Reusing
        // the pin here would make the contract's clone rule unfireable.
        let instanceID = try BridgeInstanceID.loadOrCreate(in: home)

        // Pairing survives the process. A grant ends when the user unpairs
        // (FR-027) or the certificate changes (constitution §V); a restart is
        // neither. `throws` on a corrupt file rather than starting empty —
        // starting empty would unpair every device on this Mac without anyone
        // having asked, and the user would see only that their phone stopped
        // connecting.
        let tokens = try TokenStore(directory: home)

        let claudePath = resolveClaude()

        // Read once and used for both the pairing response and the Bonjour
        // advertisement. Two lookups would let the two disagree, and the client
        // matches on what it heard first.
        let machineName = Host.current().localizedName ?? "Mac"

        let catalog = BackendCatalog(
            backends: [ClaudeBackend.descriptor(executable: claudePath)],
            // Explicitly false: a turn does not yet survive a disconnect, and
            // the client must be told so or it waits for a result nobody kept.
            resumableTurns: false
        )

        let runners: [any TurnRunning] = claudePath.map { [ClaudeBackend(executable: $0)] } ?? []

        // Which CLI conversation each session belongs to, across restarts. In
        // memory this failed silently: a restart lost the mapping, the next turn
        // started a fresh CLI conversation, and the user saw a model that had
        // forgotten the last hour with nothing to point at.
        //
        // Resets on a corrupt file rather than throwing, unlike `tokens` above.
        // The asymmetry is deliberate: losing grants unpairs the machine, losing
        // sessions costs one fresh conversation — which is what every restart
        // used to cost anyway.
        let sessions = try SessionStore(directory: home)

        let handler = BridgeHandler(
            catalog: catalog,
            runners: runners,
            tokens: tokens,
            coordinator: TurnCoordinator(sessions: sessions),
            bridgeName: machineName,
            bridgeID: instanceID
        )

        let server = BridgeServer(identity: identity, handler: handler)
        let bound = try await server.start(port: port)
        let code = await handler.openPairing()

        // Advertised only after the listener is up. Announcing first opens a
        // window where a phone can find the service and fail to connect to it,
        // which reads to the user as a broken bridge rather than a slow one.
        //
        // A failure here is reported and survived, not fatal: manual address
        // entry exists precisely for networks that carry no multicast (VPNs,
        // guest Wi-Fi), and refusing to run would take away the workaround
        // along with the feature.
        let advertiser = BonjourAdvertiser()
        var discovery = "advertising \(BonjourAdvertiser.serviceType)"
        do {
            try advertiser.start(port: bound, name: machineName, instanceID: instanceID)
        } catch {
            discovery = "not advertising — enter the address by hand"
        }

        // Written to the file handle rather than `print`ed. `print` goes
        // through a libc stream that is *block*-buffered whenever stdout is not
        // a terminal — which is every way an operator actually runs this: under
        // `nohup`, under launchd, piped to a log. The process then parks
        // forever without exiting, so the buffer is never flushed and the
        // pairing code the user is waiting for never appears at all.
        FileHandle.standardOutput.write(Data("""

        localis-bridge

          port            \(bound)
          pin             \(identity.spkiPin)
          instance        \(instanceID)
          discovery       \(discovery)
          claude          \(claudePath == nil ? "not found — backend unavailable" : "found")

          pairing code    \(code)      (valid \(Int(PairingSession.lifetime))s)


        """.utf8))

        // Park. The server runs on its own event loops; this task has nothing
        // left to do except not exit.
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// The port from the environment, when it is set to something usable.
    private static var environmentPort: Int? {
        guard let raw = ProcessInfo.processInfo.environment["LOCALIS_BRIDGE_PORT"],
              let port = Int(raw),
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    /// Finds the `claude` binary once, at startup.
    ///
    /// Resolved here and injected rather than looked up per turn: a per-turn
    /// lookup makes which binary runs depend on the environment of the moment.
    ///
    /// **Known install locations are tried before `PATH`.** This is not
    /// hypothetical tidiness — on this project's own machines `which claude`
    /// resolves to a wrapper shim in a temporary directory, installed by a
    /// terminal multiplexer, which re-`exec`s the real binary after editing
    /// `PATH`. Running a turn through it works until the temp directory is
    /// cleaned up, at which point every turn fails with `backend_unavailable`
    /// and nothing on the phone can explain why.
    private static func resolveClaude() -> String? {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["LOCALIS_CLAUDE_PATH"] {
            // An explicit override is obeyed exactly, including refusing it if
            // it is not executable. Silently falling back to a search would run
            // a different binary than the operator named.
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }

        let known = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
        ]
        if let found = known.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return found
        }

        guard let path = whichClaude(), !isShim(path) else { return nil }
        return path
    }

    /// Whether a resolved path looks like a wrapper rather than the CLI.
    ///
    /// Refused rather than used: a shim under a temporary directory disappears
    /// on reboot, and a bridge that resolved one at startup would keep the dead
    /// path for as long as the process lives.
    private static func isShim(_ path: String) -> Bool {
        path.contains("-cli-shims") || path.hasPrefix("/var/folders/") || path.hasPrefix("/tmp/")
    }

    /// `PATH` lookup, as a last resort.
    private static func whichClaude() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }
}
