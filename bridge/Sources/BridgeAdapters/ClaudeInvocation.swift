import Foundation

/// One claude CLI invocation, as a value.
///
/// Separated from the process that runs it so the arguments can be tested
/// without spawning anything. That matters more than it sounds: a wrong
/// argument does not fail loudly — the process still starts and the failure
/// surfaces as an empty stream or a conversation that forgot itself.
public struct ClaudeInvocation: Sendable, Hashable {
    /// What the user typed.
    public let prompt: String
    /// claude's own session id from a previous turn, if this continues one.
    /// Not the contract's session id — that one means nothing to the CLI.
    public let resuming: String?
    /// The directory to run in, or nil to inherit this process's.
    public let workspace: String?

    public init(prompt: String, resuming: String? = nil, workspace: String? = nil) {
        self.prompt = prompt
        self.resuming = resuming
        self.workspace = workspace
    }

    /// The argument vector.
    ///
    /// A vector, never a shell string. `Process` executes the binary directly,
    /// so the prompt stays one element whatever it contains — no quoting rules
    /// to get right, and nothing in a prompt can become a command.
    ///
    /// **No credential appears here.** The CLI authenticates from the user's
    /// own login on this machine (constitution I), and an argument vector is
    /// readable via `ps` by anything running as this user.
    public var arguments: [String] {
        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            // Partial messages are the whole point: without them the CLI emits
            // one complete message at the end and the reply lands as a block,
            // which is a different product.
            "--include-partial-messages",
            // Not optional despite the name. The CLI rejects
            // `--output-format stream-json` under `--print` without it, exiting
            // with a usage error before producing a byte.
            "--verbose",
        ]

        // Omitted rather than passed empty on a first turn: an empty
        // `--resume` makes the CLI reject the invocation outright.
        if let resuming, !resuming.isEmpty {
            arguments.append(contentsOf: ["--resume", resuming])
        }

        return arguments
    }

    /// The working directory, or nil to inherit.
    ///
    /// nil means inherit, never "/". A CLI started at the filesystem root would
    /// see none of the user's project and answer questions about the wrong
    /// tree.
    public var workingDirectory: String? {
        workspace.flatMap { $0.isEmpty ? nil : $0 }
    }
}
