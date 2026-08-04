import Foundation
import Testing

@testable import BridgeAdapters

/// How a claude CLI invocation is assembled.
///
/// Tested as a value rather than by running the CLI: the arguments are where a
/// mistake is both easy and invisible — the process still starts, and the
/// failure appears as an empty stream or a lost conversation rather than as an
/// error.
@Suite("ClaudeInvocation — command construction")
struct ClaudeInvocationTests {
    /// `--verbose` is not optional here despite its name. The CLI refuses
    /// `--output-format stream-json` under `--print` without it, exiting with a
    /// usage error before producing a byte — so omitting it breaks every turn,
    /// not just verbose ones.
    @Test("streaming requires the flags the CLI insists on")
    func streamingFlags() {
        let arguments = ClaudeInvocation(prompt: "hi").arguments

        #expect(arguments.contains("--output-format"))
        #expect(arguments.contains("stream-json"))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(arguments.contains("--verbose"))
    }

    /// The prompt goes after `-p` as its own argument, never interpolated into
    /// a shell string. There is no shell in the picture — `Process` takes an
    /// argument vector — and this test pins that the prompt stays one element
    /// no matter what it contains.
    @Test("the prompt is a single argument, not shell text", arguments: [
        "hello",
        "rm -rf /; echo pwned",
        "$(whoami)",
        "a\nb",
    ])
    func promptIsOneArgument(prompt: String) throws {
        let arguments = ClaudeInvocation(prompt: prompt).arguments

        let flag = try #require(arguments.firstIndex(of: "-p"))
        #expect(arguments[flag + 1] == prompt)
        #expect(arguments.filter { $0 == prompt }.count == 1)
    }

    /// A continuing conversation passes `--resume` with the id claude itself
    /// issued. Without it every turn starts a fresh conversation and the model
    /// sees no history — which reads to the user as amnesia rather than as a
    /// bug.
    @Test("a known session resumes rather than starting over")
    func resumesKnownSession() throws {
        let invocation = ClaudeInvocation(prompt: "next", resuming: "sess-1")

        let flag = try #require(invocation.arguments.firstIndex(of: "--resume"))
        #expect(invocation.arguments[flag + 1] == "sess-1")
    }

    /// The first turn has no id to resume from. Passing an empty `--resume`
    /// would make the CLI reject the invocation outright.
    @Test("a first turn passes no resume flag")
    func firstTurnHasNoResume() {
        #expect(!ClaudeInvocation(prompt: "first").arguments.contains("--resume"))
    }

    /// The workspace is the process's working directory, not an argument.
    /// Leaving it nil must mean "inherit", not "use /" — a CLI started at the
    /// filesystem root would see none of the user's project.
    @Test("the workspace becomes the working directory")
    func workspaceIsWorkingDirectory() {
        #expect(ClaudeInvocation(prompt: "x", workspace: "/w").workingDirectory == "/w")
        #expect(ClaudeInvocation(prompt: "x").workingDirectory == nil)
    }

    /// Constitution I: the bridge holds no backend credentials and passes none.
    /// The CLI authenticates itself from the user's own login on this machine.
    /// An argument vector is visible in `ps` to every process on the system, so
    /// a token here would be readable by anything running as this user.
    @Test("no credential ever appears in the argument vector")
    func noCredentialsInArguments() {
        let arguments = ClaudeInvocation(prompt: "x", resuming: "s", workspace: "/w").arguments

        for suspicious in ["--api-key", "--token", "ANTHROPIC_API_KEY", "Bearer"] {
            #expect(!arguments.contains { $0.contains(suspicious) })
        }
    }
}
