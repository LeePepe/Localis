import Foundation
import Testing

@testable import TransportKit

/// Mechanical checks of the rules that reviews miss.
///
/// These read the package's own source. A prose rule that nothing enforces
/// decays the first time someone is in a hurry; the point of these tests is
/// that the decay fails CI instead of shipping.
@Suite("Architecture invariants")
struct ArchitectureTests {
    /// Every Swift file in `Sources/TransportKit`.
    private static func sourceFiles() throws -> [(name: String, text: String)] {
        // #filePath rather than Bundle: the sources are not resources, and
        // walking up from this file works the same in Xcode and in SwiftPM.
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sources = testsDirectory
            .deletingLastPathComponent()   // TransportKitTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Sources/TransportKit")

        let urls = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        #expect(urls.isEmpty == false, "no sources found — this suite would pass vacuously")

        return try urls.map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Source lines with comments and doc comments removed.
    ///
    /// Backend names are legitimate *in prose* — the contract discussion names
    /// Claude Code and Codex — and a check that cannot tell code from a comment
    /// would either fire on documentation or push people to stop writing it.
    private static func codeLines(of text: String) -> [(number: Int, text: String)] {
        var inBlockComment = false

        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, rawLine in
                var line = String(rawLine)

                if inBlockComment {
                    guard let end = line.range(of: "*/") else { return nil }
                    inBlockComment = false
                    line = String(line[end.upperBound...])
                }
                if let start = line.range(of: "/*") {
                    inBlockComment = true
                    line = String(line[..<start.lowerBound])
                }
                if let comment = Self.commentStart(in: line) {
                    line = String(line[..<comment])
                }

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : (number: index + 1, text: trimmed)
            }
    }

    /// Index where a line comment starts, ignoring `//` inside a string.
    ///
    /// Naive `range(of: "//")` finds the slashes in `"http://…"` and truncates
    /// the line there — which silently disabled the plaintext-URL check until a
    /// mutation test caught it. A comment marker only counts outside quotes.
    private static func commentStart(in line: String) -> String.Index? {
        var inString = false
        var escaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)

            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString, character == "/", next < line.endIndex, line[next] == "/" {
                return index
            }

            index = next
        }

        return nil
    }

    /// Constitution IV, non-negotiable: backends are data pulled from
    /// `/v1/models`, never code.
    ///
    /// The moment a backend name appears in a condition, adding the sixth
    /// backend needs an iOS release — which is the coupling the whole
    /// single-protocol architecture exists to remove. This catches it in the
    /// commit that introduces it, when it is one line, rather than in review a
    /// month later when six places depend on it.
    @Test("no backend name appears in transport code")
    func noBackendNamesInCode() throws {
        let names = ["claude", "codex", "kimi", "gemini", "hermes", "ollama", "copilot", "openai", "anthropic"]

        for file in try Self.sourceFiles() {
            for line in Self.codeLines(of: file.text) {
                let lowered = line.text.lowercased()
                for name in names where lowered.contains(name) {
                    Issue.record(
                        """
                        \(file.name):\(line.number) names the backend '\(name)' in code.
                        Constitution IV: backends are capability data from /v1/models, \
                        never a branch. Test for a capability instead.
                        \(line.text)
                        """
                    )
                }
            }
        }
    }

    /// Constitution V: there is no plaintext path, and no way to add one by
    /// accident.
    @Test("no source constructs a plaintext URL")
    func noPlaintextURLs() throws {
        for file in try Self.sourceFiles() {
            for line in Self.codeLines(of: file.text) where line.text.contains("http://") {
                Issue.record("\(file.name):\(line.number) builds a plaintext URL: \(line.text)")
            }
        }
    }

    /// Constitution II: strict concurrency with no escape hatches. Each of
    /// these silences the compiler on exactly the reasoning that keeps the
    /// stream actors sound.
    @Test("no concurrency escape hatches", arguments: [
        "@unchecked Sendable",
        "nonisolated(unsafe)",
        "@preconcurrency",
    ])
    func noConcurrencyEscapeHatches(_ hatch: String) throws {
        for file in try Self.sourceFiles() {
            for line in Self.codeLines(of: file.text) where line.text.contains(hatch) {
                Issue.record("\(file.name):\(line.number) uses \(hatch): \(line.text)")
            }
        }
    }

    /// Constitution I: nothing in this package logs.
    ///
    /// The transport handles tokens, prompts and completions. A `print` added
    /// while debugging is how health-data-style leaks reach a console, and it
    /// survives review far more often than it should.
    @Test("no logging in the transport")
    func noLogging() throws {
        for file in try Self.sourceFiles() {
            for line in Self.codeLines(of: file.text) {
                let offender = ["print(", "debugPrint(", "NSLog(", "dump("]
                    .first { line.text.contains($0) }
                guard let offender else { continue }

                Issue.record(
                    """
                    \(file.name):\(line.number) calls \(offender). The transport carries \
                    tokens and conversation content; constitution I allows neither near a log.
                    \(line.text)
                    """
                )
            }
        }
    }

    /// Constitution V: the type that can build an **unpinned** session must not
    /// be constructible from outside this package.
    ///
    /// `PinnedHTTP(pin:)` accepts `SPKIHash?`, and nil refuses every connection
    /// (`PinnedTrust.swift:41`) — so the danger is not that a nil-pinned session
    /// connects insecurely, it is that a caller outside the package could build
    /// a session at all and, later, be handed a way to relax it. The public way
    /// in is `BridgePairing(pinnedTo:)`, whose pin is non-optional, which makes
    /// "pair without a pin" unexpressible rather than merely discouraged
    /// (Amendment E §3).
    ///
    /// **Checked by sweeping source, because a test cannot assert an absence.**
    /// Writing `PinnedHTTP(...)` in a non-`@testable` test file is a compile
    /// error, which fails the build rather than the test — so there is nothing
    /// for `PublicSurfaceTests` to express, and the guard has to be this.
    @Test("the unpinned session type is not public")
    func pinnedSessionStaysInternal() throws {
        let files = try Self.sourceFiles()
        let carrier = files.first { $0.name == "PinnedTrust.swift" }

        // Without this the sweep passes vacuously the day the file is renamed —
        // the same shape as a `--filter` that matches nothing.
        let text = try #require(carrier?.text, "PinnedTrust.swift is gone; this rule stopped being checked")

        for line in Self.codeLines(of: text) {
            for shape in ["public struct PinnedHTTP", "public init(\n", "open struct PinnedHTTP"]
            where line.text.hasPrefix(shape) {
                Issue.record(
                    """
                    PinnedTrust.swift:\(line.number) exposes the unpinned session type. \
                    Outside this package the only way to a session must be \
                    `BridgePairing(pinnedTo:)`, whose pin cannot be nil (Amendment E §3).
                    \(line.text)
                    """
                )
            }
        }

        // The initialiser separately: it is on `PinnedHTTP` and could be widened
        // without the type declaration changing.
        let declaration = "struct PinnedHTTP"
        let lines = Self.codeLines(of: text)
        guard let start = lines.firstIndex(where: { $0.text.contains(declaration) }) else {
            Issue.record("`\(declaration)` not found — this rule is checking nothing")
            return
        }
        #expect(
            lines[start].text.hasPrefix("struct "),
            "PinnedHTTP must be internal; found: \(lines[start].text)"
        )
    }

    /// Amendment A §1.1: a client speaks to **one** host.
    ///
    /// `BridgeDiscovery` is the deliberate exception — it emits sightings one at
    /// a time and keeps no collection — so the sweep names the files that carry
    /// a host's credentials rather than the whole package. In those, a
    /// collection of hosts is the shape that lets one machine's token or pinned
    /// certificate reach a request bound for another (FR-028), and it would look
    /// entirely reasonable at the call site.
    @Test("credential-carrying code cannot address more than one host")
    func noMultiHostInCredentialPath() throws {
        let scoped: Set<String> = ["BridgeClient.swift", "BridgePairing.swift", "HostCredentialStore.swift"]
        let files = try Self.sourceFiles().filter { scoped.contains($0.name) }

        #expect(
            files.count == scoped.count,
            "a file in this sweep was renamed or removed — the rule stopped being checked"
        )

        for file in files {
            for line in Self.codeLines(of: file.text) {
                for shape in ["[LocalisHost]", "[HostID]", "[HostEndpoint]"] where line.text.contains(shape) {
                    Issue.record(
                        """
                        \(file.name):\(line.number) holds \(shape). This layer is per-host: \
                        one token, one pin, one protocol version. Multi-host orchestration \
                        belongs above it (Amendment A §1.1).
                        \(line.text)
                        """
                    )
                }
            }
        }
    }
}
