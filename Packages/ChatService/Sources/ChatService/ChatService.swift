import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// Orchestrates one chat turn: validate → persist the user message → stream the
/// reply → persist each update.
///
/// This is the only place that knows the *order* of those steps. It depends on
/// `AgentTransport` and `SessionRepository` as protocols, so it is fully
/// testable against fakes with no live agent and no disk.
public actor ChatService {
    private let transport: any AgentTransport
    private let repository: any SessionRepository
    /// Injected so tests get deterministic timestamps and ids.
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        transport: any AgentTransport,
        repository: any SessionRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.transport = transport
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    /// Sends `prompt` in `session` and streams the assistant reply.
    ///
    /// Each yielded `Session` is a complete new snapshot with the assistant
    /// message updated — the view renders the latest one and never mutates.
    ///
    /// - Throws: `LocalisError.invalidInput` for an empty prompt. Transport
    ///   failures surface as a `.failed` assistant message rather than a throw,
    ///   so the transcript keeps the partial text the user already saw.
    public func send(
        prompt: String,
        in session: Session,
        to backend: AgentBackend
    ) async throws -> AsyncThrowingStream<Session, Error> {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalisError.invalidInput(field: "message")
        }

        let userMessage = Message(id: makeID(), role: .user, text: trimmed, createdAt: now())
        let withUser = session.appending(userMessage, at: now())
        try await repository.save(withUser)

        let placeholder = Message(
            id: makeID(),
            role: .assistant,
            text: "",
            createdAt: now(),
            status: .streaming
        )
        let withPlaceholder = withUser.appending(placeholder, at: now())
        try await repository.save(withPlaceholder)

        let request = TurnRequest(
            backendID: backend.id,
            sessionID: session.id,
            // The bridge wants the conversation ending with what to answer, not
            // a history and a prompt kept apart. `withUser` already has the new
            // turn appended, so this is that list exactly.
            //
            // Sending the whole transcript is the reading that fails loudly if
            // it is the wrong one: a bridge that keeps its own session state
            // just wastes tokens on the repeat, whereas under-sending to a
            // stateless one makes the agent forget every turn — and that shows
            // up as "the answers got strange", not as an error anyone can find.
            messages: withUser.messages
            // `workspace` is deliberately left at its default. Not an oversight
            // and not a decision made here: `Session` has no workspace field to
            // send. FR-013 puts the directory behind the backend's `workspace`
            // capability, so the picker, the stored path, and this argument are
            // one piece of work that has not been done. Passing `nil` is the
            // honest state — the header is then omitted entirely, which is not
            // the same as sending an empty one.
        )
        let turn = try await transport.send(request)

        return AsyncThrowingStream { continuation in
            Task { [repository, now] in
                var current = withPlaceholder
                var assistant = placeholder
                // The resume point. Seeded from the turn id, which arrives in
                // the response header *before* any frame — which is what makes
                // the worst case decidable: a connection that dies before the
                // first event is still a turn the Mac is generating, and
                // without the id it would be indistinguishable from one that
                // never started.
                var cursor = turn.turnID.map { TurnCursor(turnID: $0) }
                continuation.yield(current)

                do {
                    for try await sequenced in turn.events {
                        // Dedup before anything else. On resume the bridge may
                        // replay frames around the boundary, and appending a
                        // replayed delta shows the user duplicated words
                        // (SC-003: no missing text, no duplicated text).
                        //
                        // A frame with no `seq` is always kept: absent means
                        // "this host cannot resume", not "sequence zero", and
                        // repeating the same word twice is ordinary in a
                        // healthy stream.
                        //
                        // `shouldAccept`, not `accepts`: a `SequencedEvent`
                        // carries no turn id, and one `TurnStream` is one
                        // turn's frames by construction, so there is no second
                        // turn here to confuse this one with. Passing the
                        // cursor's own id in as the incoming one would look
                        // like the stronger check while comparing a value to
                        // itself — the shape that reads as safe and is not.
                        if let seq = sequenced.seq, let cursor {
                            guard cursor.shouldAccept(seq: seq) else { continue }
                        }
                        if let seq = sequenced.seq {
                            cursor = cursor?.advanced(to: seq)
                        }

                        switch sequenced.event {
                        case .delta(let text):
                            assistant = assistant.appending(text)

                        case .turnEnd(let end):
                            guard let settled = Self.settle(assistant, on: end, at: now()) else {
                                // A non-terminal outcome this build cannot name
                                // (`.unknown`). Letting the stream run on is
                                // right: the frames that follow decide, and
                                // guessing `.complete` here would report an
                                // unfinished turn as answered.
                                continue
                            }
                            assistant = settled
                            current = current
                                .replacing(assistant, at: now())
                                .withStatus(Self.sessionStatus(for: end))
                            try? await repository.save(current)
                            continuation.yield(current)
                            continuation.finish()
                            return

                        // Tool calls, approvals, activity phrases, telemetry and
                        // usage are all real features with their own work to do;
                        // wiring them up is a separate piece. What matters here
                        // is that an unconsumed frame must not break the turn —
                        // the same rule the mapper follows for frames it cannot
                        // parse at all.
                        case .toolCall, .approvalRequired, .sessionStatus,
                             .telemetry, .usage, .finished, .done:
                            continue
                        }
                        current = current.replacing(assistant, at: now())
                        try await repository.save(current)
                        continuation.yield(current)
                    }
                    // A stream that ends without an explicit `.completed` is
                    // still a finished turn — don't strand it as `.streaming`.
                    if assistant.status == .streaming {
                        assistant = assistant.withStatus(.complete)
                        current = current.replacing(assistant, at: now())
                    }
                    // A turn that finished clears any error the previous one
                    // left behind. Without this, one bad turn marks the
                    // conversation broken for good: `canSend` stays false and
                    // the composer refuses input on a session that works
                    // (FR-053).
                    current = current.withStatus(.idle)
                    try await repository.save(current)
                    continuation.yield(current)
                } catch {
                    // Keep the partial text the user already read, and settle
                    // it by the one rule rather than assuming the worst: a
                    // stream that dies under us is not automatically `.failed`.
                    let reason = Self.localisError(from: error)
                    let settled = Self.settledStatus(for: reason, cursor: cursor)
                    assistant = assistant.withStatus(settled)
                    current = current
                        .replacing(assistant, at: now())
                        .withStatus(Self.sessionStatus(for: settled, reason: reason))
                    try? await repository.save(current)
                    continuation.yield(current)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Reconnect

    /// Opens the link a restored session does not have, and reports what it
    /// found (#25).
    ///
    /// **The deadlock this closes.** `Session.canSend` is `status == .idle`, and
    /// every read path normalizes a stored session to `.disconnected` — rightly,
    /// because the process holds no connection after a relaunch and `.idle`
    /// means *connected and not busy*. But until this existed, the only writes
    /// producing `.idle` were at the end of a completed turn, and starting a
    /// turn requires `canSend`. The state was entered on every cold start and
    /// left by nothing: every conversation from yesterday had a permanently grey
    /// composer, with no error anywhere to explain it.
    ///
    /// **`.error` was the same dead end**, and reachable without a relaunch:
    /// `sessionStatus(for:)` clears it when a later turn ends, and that turn
    /// could not be started. One dropped connection closed the conversation for
    /// good.
    ///
    /// **Why this probes instead of assuming.** Writing `.idle` because the user
    /// opened the screen restores the composer by asserting a connection nobody
    /// checked — FR-053 inverted, and precisely what the normalization exists to
    /// prevent. The host is asked, and its answer is what gets written. A silent
    /// Mac leaves the session exactly as it was.
    ///
    /// **This never throws.** It runs on open, and reading is never gated
    /// (FR-036): a failure to reach the Mac must leave the transcript readable
    /// rather than replacing it with an error screen. An unreachable host is
    /// already fully expressed by the status coming back unchanged.
    public func reconnect(_ session: Session, to backend: AgentBackend) async -> Session {
        guard Self.isReconnectable(session.status) else { return session }
        // The Mac being up is not enough. A backend the host lists but is not
        // signed into would let a session report as sendable and then fail at
        // the far end — the accept-then-fail shape FR-053 rules out. Checked
        // before the probe, so no request goes out for an answer already known.
        guard backend.isAvailable else { return session }
        // Only `.reachable` reconnects. `.unknown` is not a green light: it
        // means no probe has established anything, and treating it as reachable
        // would be the accept-then-fail shape again, one layer up. The reason a
        // failure carries (#40) is for the host list to display; here the
        // question is binary, and collapsing it at the point of use keeps this
        // guard behaving exactly as it did when `probe` returned `Bool`.
        guard await transport.probe(backend) == .reachable else { return session }

        let reconnected = session.withStatus(.idle)

        // Persisted only when the previous status was one a read gives back.
        //
        // `restoredStatus` (StoredMapping.swift:99) returns `.error` unchanged
        // and collapses `.idle/.disconnected/.connecting/.streaming` to
        // `.disconnected`. So from `.disconnected` or `.connecting` this write
        // stores a status that the very next read turns back into what was
        // already there — it cannot change any later answer, and the guard
        // keeps a pointless write off the disk on every screen open.
        //
        // From `.error` the write is the point. That one does survive a read,
        // so a session left failed comes back failed on every launch, forever,
        // with `canSend` false and no turn permitted to clear it. Replacing it
        // makes the next read `.disconnected` — still not sendable, but a state
        // this same call can lift.
        //
        // **This guard used to carry a second job that it no longer has to.**
        // `withStatus` took a timestamp and bumped `updatedAt`, which is the
        // list's sort key, so any save here pushed a conversation to the top
        // because the user *opened* it — indistinguishable on screen from a
        // reply arriving. Skipping the write avoided that for two of the three
        // statuses and did nothing for `.error`, which still jumped the queue
        // every time a failed conversation recovered. That is fixed where it
        // was actually caused: `withStatus` no longer touches `updatedAt` at
        // all (#28, Session.swift), so a save here is now just a save. Both
        // halves are pinned by `ChatServiceReconnectTests` —
        // `reconnectingDisconnectedDoesNotTouchTheRow` for the skipped write,
        // `recoveringDoesNotTouchTheRowsPosition` for the one that happens.
        //
        // `try?`: the reconnect succeeded, and a store that could not record it
        // must not turn a working link into a closed composer. The in-memory
        // status is the one the user is about to type against.
        if case .error = session.status {
            try? await repository.save(reconnected)
        }
        return reconnected
    }

    /// Which statuses a probe is allowed to change.
    ///
    /// Exhaustive with no `default`, so a new status has to be given an answer
    /// here rather than inheriting one — and the safe inheritance would be the
    /// wrong one in both directions.
    private static func isReconnectable(_ status: SessionStatus) -> Bool {
        switch status {
        case .disconnected, .connecting, .error:
            // `.error` included deliberately: a turn that failed because the
            // link died is exactly the case a successful probe should lift, and
            // leaving it out is how the second dead end survived.
            return true
        case .idle:
            // Already sendable. Probing would put a request on the wire every
            // time the user taps into a conversation, for an answer that changes
            // nothing.
            return false
        case .streaming:
            // A turn is in flight. Writing `.idle` over it hands the composer
            // back mid-turn and invites a second send on top of the first.
            return false
        case .orphaned:
            // A fact about *pairing*, not about a connection, and it outranks
            // any liveness answer. The bridge may be up and reachable; the user
            // still revoked it, and FR-027 keeps the transcript readable and
            // unsendable rather than deleting it.
            return false
        }
    }

    /// Maps anything thrown out of the transport into the one error vocabulary.
    ///
    /// `AgentTransport` conformers are required to map their own failures
    /// before they escape, so a foreign error arriving here means that rule was
    /// broken somewhere upstream. It still must not get past this layer: a
    /// `URLError` reaching the UI renders as text no user can read, and its
    /// description can carry a full endpoint (constitution I).
    ///
    /// `connectionLost` is the honest fallback — the turn did stop mid-flight,
    /// and it is the reading that stays retryable, which is the safe answer
    /// when the real cause is unknown.
    private static func localisError(from error: any Error) -> LocalisError {
        error as? LocalisError ?? .connectionLost
    }

    /// How a turn that broke mid-flight settles.
    ///
    /// Two questions, each answered by the one place that owns it:
    ///
    /// 1. **Is the break survivable at all?** `LocalisError.isRetryable` says.
    ///    A revoked token and a dropped connection produce the same broken
    ///    stream, but resuming the first only replays the refusal — no cursor
    ///    rescues it, so it settles `.failed`.
    /// 2. **Is a survivable break resumable?** `TurnReconciliation.resolve`
    ///    says, from the cursor.
    ///
    /// Neither judgement is made here. Writing `if cursor != nil` in this file
    /// would agree with the store by coincidence, and the first refactor on
    /// either side would end the agreement silently — which is the failure mode
    /// three layers of defence exist to avoid.
    static func settledStatus(for reason: LocalisError, cursor: TurnCursor?) -> MessageStatus {
        guard reason.isRetryable else { return .failed }

        // `.streaming` is the honest input: the turn was mid-flight when the
        // link died. The store reads that as "the process that owned this
        // stream is gone", which is exactly what happened.
        switch TurnReconciliation.resolve(state: .streaming, cursor: cursor) {
        case .stillRunning:
            return .detached
        case .lost:
            return .interrupted
        case .settled, .failed:
            // Unreachable from `.streaming`, and deliberately not folded into
            // the cases above: a future `resolve` gaining a state should fail
            // here loudly rather than settle a live turn as finished.
            return .interrupted
        }
    }

    /// What the conversation reads as once its turn settled.
    ///
    /// `.detached` is the case worth spelling out: the turn is running fine on
    /// the host, so an `.error` banner would be a lie about the work. The link
    /// is what is gone, so the session reads `.disconnected` — and `canSend`
    /// stays false, which is correct, because starting a second turn while the
    /// first generates is the precise harm Amendment C §1.5 exists to prevent.
    ///
    /// **`public` so the UI can assert against it rather than restate it.**
    /// `.disconnected` here means "the link is gone, the work may well still be
    /// running", and the composer's wording depends on that reading — it offers
    /// to keep reading rather than announcing the reply is lost. That agreement
    /// was reached twice independently, in two packages, and until this was
    /// visible the only thing holding it together was that both authors
    /// happened to mean the same thing. Nothing failed if one of them changed
    /// their mind; the user just got told a running turn had died.
    public static func sessionStatus(for settled: MessageStatus, reason: LocalisError) -> SessionStatus {
        settled.isInFlight ? .disconnected : .error(reason)
    }

    /// Applies a `.turnEnd` frame to the assistant message.
    ///
    /// Returns `nil` when the outcome is one this build cannot name, so the
    /// caller keeps reading rather than guessing — reporting an unfinished turn
    /// as answered is worse than waiting for the frames that decide.
    ///
    /// The failure branch is the one that closes the gap this seam existed to
    /// create: `TurnFailure` reaches the *message*, which is what survives a
    /// relaunch. The whole chain below this point was already built for it —
    /// the store persists it, the UI renders "failed 8 minutes in, after 3 tool
    /// calls" — and the old three-case seam was the only thing dropping it.
    private static func settle(_ message: Message, on end: TurnEnd, at date: Date) -> Message? {
        switch end.outcome {
        case .completed:
            return message.withStatus(.complete)
        case .cancelled:
            // The user asked for this, so it is not a failure to report back
            // to them. Nothing is still running, so a retry is safe.
            return message.withStatus(.interrupted)
        case .failed:
            // A failure is a fact the moment the bridge says `outcome: failed`,
            // whether or not the numbers came with it. The store's
            // reconciliation degrades a detail-less failure to `.settled` —
            // which loses both the failure and the retry — but that path only
            // sees two persisted columns. Here the frame itself was observed,
            // so there is nothing to infer.
            //
            // What is *not* done: filling a missing field with `0`. "Failed 0
            // minutes in, after 0 tool calls" is a fabricated claim, and the
            // UI already drops the detail line when it is absent rather than
            // rendering zeros. Both fields or neither — a half-invented record
            // is the one shape that reads as true and is not.
            guard
                let failedAtMs = end.failedAtMs,
                let toolCallsCompleted = end.toolCallsCompleted
            else {
                return message.withStatus(.failed)
            }
            return message.failed(
                TurnFailure(failedAtMs: failedAtMs, toolCallsCompleted: toolCallsCompleted)
            )
        case .unknown:
            return nil
        }
    }

    /// What the conversation reads as once the bridge ended the turn.
    private static func sessionStatus(for end: TurnEnd) -> SessionStatus {
        switch end.outcome {
        case .completed, .cancelled, .unknown:
            // Clears any error a previous turn left behind, so one bad turn
            // does not mark the conversation broken for good (FR-053).
            return .idle
        case .failed:
            return .error(LocalisError(wireCode: end.errorCode))
        }
    }
}
