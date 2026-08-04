import Foundation
import LocalisModels
import TransportKit

/// A fake `AgentTransport` that replies to itself, for milestone A only.
///
/// ---- Read this before using it anywhere ----
///
/// This connects to nothing. There is no Mac, no bridge, no agent, no network.
/// It exists so milestone A can prove the *assembly* works — that a tap in the
/// composer reaches `ChatService`, that `ChatService` persists through
/// `SwiftDataSessionRepository`, that streamed snapshots reach `TranscriptView`,
/// and that all of it survives a relaunch. Every one of those is a real seam
/// between real layers. Only the far end is fake.
///
/// **Why a fake is dangerous here specifically.** A hardcoded
/// `InMemorySessionRepository` is how this project ended up with seven packages,
/// 538 passing tests, and an app that could not open a conversation: a stand-in
/// that made everything look connected, and no pressure to replace it because
/// nothing was visibly broken. This type is the same shape. It is admitted only
/// because milestone B deletes it, and it is built to be impossible to mistake
/// for the real thing in the meantime:
///
///   1. **It says so at runtime.** `displayLabel` is rendered in the UI, so a
///      screenshot of a fake conversation cannot be mistaken for a real one.
///      Screenshots travel further than code does, and the danger of a demo
///      fake is not in the code — it is in the impression the picture leaves.
///   2. **It is not in `Packages/`.** Inside a package it would become shared
///      infrastructure, get imported by something else, and grow dependents
///      that make it expensive to delete. Here, only the app can see it.
///   3. **Its replies are visibly canned.** It echoes the prompt back rather
///      than saying anything plausible. A fake that produces convincing prose
///      is one screenshot away from being believed.
///
/// Milestone B deletes this file and constructs a real `BridgeClient`. The
/// deletion is a tracked item, not an intention.
struct EchoTransport: AgentTransport {
    /// Shown in the UI wherever this transport is in use. Not decoration — it
    /// is the runtime evidence that requirement 1 above is actually met.
    static let displayLabel = "Echo (fake)"

    /// Delay between streamed chunks. Slow enough that the reply visibly
    /// arrives in pieces — milestone A has to *show* streaming, and text that
    /// appears all at once demonstrates nothing about the stream loop.
    private let chunkDelay: Duration

    init(chunkDelay: Duration = .milliseconds(90)) {
        self.chunkDelay = chunkDelay
    }

    func send(_ request: TurnRequest) async throws -> TurnStream {
        // The prompt is the last message: `TurnRequest.messages` is the whole
        // conversation, oldest first, ending with what to answer.
        let prompt = request.messages.last?.text ?? ""
        let chunks = Self.reply(to: prompt)
        let delay = chunkDelay

        // A turn id is supplied because the real bridge sends one and the
        // resume path keys off it. Prefixed `echo-` so anything that logs or
        // displays it cannot be confused with a bridge-issued id.
        let turnID = "echo-\(request.sessionID.uuidString.prefix(8))"

        let events = AsyncThrowingStream<SequencedEvent, Error> { continuation in
            let task = Task {
                var seq = 0
                for chunk in chunks {
                    // Cancellation is checked, not assumed: the composer's stop
                    // button cancels the consuming task, and a fake that
                    // ignored that would make the stop button look like it
                    // works while the stream ran to completion behind it.
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { break }
                    continuation.yield(SequencedEvent(seq: seq, event: .delta(chunk)))
                    seq += 1
                }

                if Task.isCancelled {
                    continuation.yield(
                        SequencedEvent(
                            seq: seq,
                            event: .turnEnd(TurnEnd(turnID: turnID, outcome: .cancelled))
                        )
                    )
                } else {
                    continuation.yield(
                        SequencedEvent(seq: seq, event: .finished(reason: "stop"))
                    )
                    continuation.yield(
                        SequencedEvent(
                            seq: seq + 1,
                            event: .turnEnd(TurnEnd(turnID: turnID, outcome: .completed))
                        )
                    )
                }
                continuation.yield(SequencedEvent(seq: nil, event: .done))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return TurnStream(turnID: turnID, events: events)
    }

    /// Always reachable — there is nothing to be unreachable.
    func probe(_ backend: AgentBackend) async -> HostReachability { .reachable }

    /// Echoes the backend back unchanged, always available.
    ///
    /// There is no host to ask, so there is nothing that could be signed out.
    /// `.listed` rather than `.unknown` deliberately: `.unknown` means "could
    /// not ask", which would leave every milestone-A conversation reporting an
    /// unreachable Mac when the fake is working exactly as intended.
    func refresh(_ backend: AgentBackend) async -> BackendDescription {
        .listed(backend)
    }

    /// The canned reply, split into streamable pieces.
    ///
    /// Deliberately states what it is in its first words. If this text ever
    /// appears in a bug report or a screenshot, the reader should not have to
    /// work out whether they are looking at a real agent.
    private static func reply(to prompt: String) -> [String] {
        let quoted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = quoted.isEmpty ? "(nothing)" : quoted
        return [
            "[\(displayLabel)] ",
            "No agent is connected. ",
            "This reply is generated on-device to exercise the streaming path. ",
            "You said: ",
            body,
        ]
    }
}
