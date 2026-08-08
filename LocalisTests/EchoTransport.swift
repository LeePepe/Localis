import Foundation
import LocalisModels
import TransportKit

/// A fake `AgentTransport` that replies to itself. **Test fixture only.**
///
/// ---- What changed, and why the old warning is no longer the point ----
///
/// This file lived in `Localis/Sources/Fakes/` for milestone A, where it was the
/// app's real far end and the screen carried a "Echo (fake)" pill so that no
/// screenshot of it could be mistaken for a live Mac. Milestone B replaced that
/// wiring with a per-host `BridgeClient` (`ChatTransport.swift`,
/// `SessionDetailModel.openService`), so the production target now contains no
/// fake at all and the pill is gone with it. The danger this file was built
/// around — a stand-in that makes the app look connected, with no pressure to
/// replace it because nothing is visibly broken — cannot recur from here: **the
/// app target cannot see this file.** It is compiled into `LocalisTests` only,
/// and a production `import` of it does not link.
///
/// **What it is for now.** It is the ordinary streaming transport for the
/// app-assembly suites: a fake that succeeds, streams in pieces, and answers
/// `.reachable` / `.listed`, so a test about *the assembly* (does a tap reach
/// `ChatService`, does a restored session become sendable) does not have to
/// restate a happy-path transport each time. Suites whose subject is a specific
/// answer from the host build their own stubs — `DescribingTransport` in
/// `BackendAvailabilityTests` for the availability cases, `RefusingTransport` in
/// `HostRevocationTests` for a refusal — because this one cannot express those.
///
/// Its replies stay visibly canned. That is no longer about screenshots; it is
/// so that this text appearing in a failure dump or a bug report identifies
/// itself immediately as a fixture rather than as something an agent said.
struct EchoTransport: AgentTransport {
    /// Written into the reply text, so a transcript captured from a test names
    /// its own source. No longer rendered anywhere in the app — the milestone-A
    /// `StatusPill` that displayed it was deleted along with the production copy
    /// of this file.
    static let displayLabel = "Echo (fake)"

    /// Delay between streamed chunks.
    ///
    /// It existed so the reply *visibly* arrived in pieces on a milestone-A
    /// screen. Nothing renders this transport now, so the default is dead weight
    /// on any test that forgets to zero it — kept, rather than removed, because
    /// `EchoTransportTests.streamsInPieces` still asserts the chunking and a
    /// transport that yielded everything at once would be a different fixture.
    /// Tests that only need a reply pass `.zero`.
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
    /// not ask", which would block the composer in every suite that uses this
    /// as its happy-path transport — reporting an unreachable Mac while the
    /// fake is working exactly as intended. A test whose subject *is* the
    /// unreachable answer builds a stub that says so (`DescribingTransport`).
    func refresh(_ backend: AgentBackend) async -> BackendDescription {
        .listed(backend)
    }

    /// The canned reply, split into streamable pieces.
    ///
    /// Deliberately states what it is in its first words. If this text ever
    /// appears in a failure dump or a bug report, the reader should not have to
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
