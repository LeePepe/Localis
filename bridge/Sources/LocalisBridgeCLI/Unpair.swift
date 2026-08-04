import BridgeCore
import Foundation

/// `localis-bridge unpair` — ends a paired device's access to this Mac.
///
/// **Why a subcommand and not a route.** Contract §1 says revocation is
/// executed one-way from the Mac side ("吊销由 Mac 侧单向执行"). An authenticated
/// HTTP endpoint would satisfy the letter of "the token stops working" while
/// inverting the security property: any paired phone could revoke a *different*
/// phone, so a stolen token would go from "read this Mac's model list" to "lock
/// the owner out of their own Mac". The operator sitting at the Mac is the one
/// the contract puts in charge, and the terminal is where they already are.
///
/// **It edits a file a running bridge has open.** A bridge that is already up
/// holds its grants in memory and will keep honouring a token this command
/// revoked until it restarts. That is stated by the command rather than papered
/// over: silently succeeding while the device still works is the failure mode
/// that matters here, and the operator can act on being told.
enum Unpair {
    /// The exit path for a usage problem. Reported as an error rather than a
    /// silent no-op, because "nothing happened" and "I revoked nothing because
    /// you typed the id wrong" look identical afterwards.
    enum Failure: Error {
        case noDeviceID
        case unknownDevice(String)
    }

    static func run(arguments: [String]) throws {
        let directory = Bridge.configurationDirectory
        let tokens = try TokenStore(directory: directory)

        // `--list` first: an operator who does not know the id cannot revoke
        // anything, and the ids are not memorable.
        if arguments.first == "--list" || arguments.isEmpty {
            try listDevices(tokens)
            // An empty argument list is a usage error *after* the listing, not
            // instead of it — printing the ids and then saying which one is
            // missing is more use than either half alone.
            if arguments.isEmpty { throw Failure.noDeviceID }
            return
        }

        let deviceID = arguments[0]
        let ended = try revoke(deviceID: deviceID, in: tokens)

        // The device *name* is printed and the id echoed; the token never is.
        // The operator needs to see which device they just removed — a bare
        // "done" leaves them unable to tell they revoked the wrong one.
        for grant in ended {
            let name = grant.deviceName.isEmpty ? "(unnamed device)" : grant.deviceName
            write("unpaired \(name) [\(grant.deviceID)]")
        }
        write("its token now answers 401 token_revoked")
        write("a bridge that is already running keeps the old grants until it restarts")
    }

    /// Revokes, or reports that nothing matched.
    ///
    /// The empty result is an error rather than a success with a count of zero:
    /// a mistyped id must not read as "device removed", because the operator's
    /// next act is to stop worrying about that device.
    private static func revoke(deviceID: String, in tokens: TokenStore) throws -> [TokenStore.Grant] {
        let ended = runBlocking { await tokens.revoke(deviceID: deviceID) }
        guard !ended.isEmpty else { throw Failure.unknownDevice(deviceID) }
        return ended
    }

    private static func listDevices(_ tokens: TokenStore) throws {
        let devices = runBlocking { await tokens.pairedDevices }

        guard !devices.isEmpty else {
            write("no paired devices")
            return
        }

        write("paired devices:")
        for device in devices {
            let name = device.deviceName.isEmpty ? "(unnamed device)" : device.deviceName
            write("  \(device.deviceID)  \(name)")
        }
    }

    /// Runs an async call to completion from this synchronous entry point.
    ///
    /// `main()` is async, but the actor hop still needs a bridge from the
    /// non-async helpers above. A semaphore rather than `await` throughout
    /// because this command is a few file reads and one write — there is no
    /// concurrency here to preserve, and threading `async` through the printing
    /// helpers would buy nothing.
    ///
    /// The result comes back through a stream rather than a mutable box: an
    /// `Optional` that must be unwrapped after the wait is a force-unwrap
    /// justified only by an ordering the compiler cannot see, and "the
    /// synchronisation makes this safe" is the same sentence that precedes most
    /// concurrency bugs. `first(where:)` on a one-element stream carries the
    /// value out with no optional to defeat.
    private static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let stream = AsyncStream<T> { continuation in
            Task {
                continuation.yield(await work())
                continuation.finish()
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let collected = Collected<T>()
        Task {
            for await value in stream {
                collected.store(value)
                break
            }
            semaphore.signal()
        }
        semaphore.wait()
        return collected.take()
    }

    /// Carries the single result out of the `Task` above.
    ///
    /// `@unchecked` with no lock: the semaphore is the synchronisation — the
    /// write happens before `signal()` and the read after `wait()`. `take()`
    /// traps rather than returning an optional, because a missing value here
    /// would mean the signal fired without the assignment, which the block above
    /// makes impossible; a crash is the honest answer if that ever changes.
    private final class Collected<T>: @unchecked Sendable {
        private var value: T?
        func store(_ newValue: T) { value = newValue }
        func take() -> T {
            guard let value else {
                preconditionFailure("the result was signalled without being stored")
            }
            return value
        }
    }

    /// Written to the file handle rather than `print`ed, for the same reason
    /// the startup banner is: `print` is block-buffered when stdout is not a
    /// terminal, so piping this to a log would reorder or lose it.
    private static func write(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }
}
