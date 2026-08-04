import ChatService
import DesignKit
import LocalisModels
import LocalisUI
import SessionStore
import SwiftUI

/// One session: its transcript, and the composer under it.
///
/// Sending goes through `ChatService`, never through the repository directly —
/// the service is the only thing that knows the *order* of persist-then-stream,
/// and a view that saved its own message would write half a turn.
///
/// The transport under that service is `EchoTransport` for milestone A, and the
/// screen says so. Everything else on the path is real: the session and its
/// backend come from the store, the turn is persisted before it streams, and it
/// is still there after a relaunch.
@MainActor
@Observable
final class SessionDetailModel {
    private(set) var messages: [MessageState] = []
    private(set) var composer: ComposerState?
    private(set) var loadError: String?
    /// The backend this session actually routes to, once resolved from the
    /// store. `nil` means the send path is not usable — see `sendBlockedReason`.
    private(set) var backend: AgentBackend?
    /// Why sending is unavailable even though the composer itself is open.
    ///
    /// Separate from `ComposerState.blockedReason`, which answers "can this
    /// *session* send" from its status. This one answers "did we find the
    /// backend it names", and the two fail for unrelated reasons: an idle
    /// session on an unpaired machine is open by status and unroutable in fact.
    private(set) var sendBlockedReason: String?

    private let repository: any SessionRepository
    private let sessionID: UUID
    private let service: ChatService
    private var session: Session?
    private var streamTask: Task<Void, Never>?

    init(repository: any SessionRepository, sessionID: UUID, service: ChatService) {
        self.repository = repository
        self.sessionID = sessionID
        self.service = service
    }

    func load() async {
        do {
            guard let session = try await repository.session(id: sessionID) else {
                // Deleted between the list rendering and the tap. Not an error
                // code — nothing failed — so it gets its own sentence rather
                // than borrowing one that would name a cause that didn't happen.
                loadError = "This session is no longer on this device."
                return
            }
            apply(session)
            await resolveBackend(for: session)
            loadError = nil
            // Only now, and only if a backend was found. A restored session
            // arrives `.disconnected` and nothing else in the app writes `.idle`
            // back, so without this line the composer stays grey for every
            // conversation that predates this launch (#25). It runs after
            // `apply` so the transcript is on screen while the probe is in
            // flight — reading is never gated (FR-036).
            await reconnectIfPossible()
        } catch {
            loadError = (error as? LocalisError)?.userMessage ?? "Please try again."
        }
    }

    /// Asks the Mac whether this conversation can be continued, and shows the
    /// answer.
    ///
    /// Silent when there is no backend to ask about: `resolveBackend` has
    /// already put the reason on screen, and a second one would be the same
    /// fact stated twice.
    ///
    /// Never throws and never sets `loadError`. An unreachable Mac is not a
    /// failure to open the conversation — the transcript is fine, and the
    /// composer's own `blockedReason` already says the link is down.
    private func reconnectIfPossible() async {
        guard let session, let backend else { return }

        let reconnected = await service.reconnect(session, to: backend)
        // Re-projected through the same path as every other snapshot, so the
        // composer is derived from the session rather than being switched on
        // here. A local `canSend = true` would be a second opinion, and the two
        // would drift.
        apply(reconnected)
    }

    /// Finds the backend this session names, on the host it belongs to.
    ///
    /// Looked up by `(hostID, backendID)`, never by `backendID` alone: a backend
    /// id is unique only within one machine (FR-029), so a bare match would let
    /// a session route to a same-named agent on a *different* Mac — and the
    /// reply would look entirely normal while coming from the wrong computer.
    ///
    /// Failure here is recorded rather than thrown. The transcript is still
    /// fully readable when the host is gone (FR-036); only sending is lost, and
    /// that is what the composer needs to be told.
    private func resolveBackend(for session: Session) async {
        do {
            let backends = try await repository.backends(ofHost: session.hostID)
            guard let match = backends.first(where: { $0.id == session.backendID }) else {
                backend = nil
                sendBlockedReason = String(
                    localized: "This conversation's agent isn't on this Mac any more."
                )
                return
            }
            backend = match
            // An unavailable backend is a different sentence from a missing one:
            // signing in fixes the first, re-pairing the second. Collapsing them
            // leaves the user with no idea which applies.
            sendBlockedReason = match.isAvailable
                ? nil
                : String(localized: "This agent isn't signed in on the Mac.")
        } catch {
            backend = nil
            sendBlockedReason = (error as? LocalisError)?.userMessage
                ?? String(localized: "Couldn't check which agent this conversation uses.")
        }
    }

    /// Sends the composer's draft, if there is somewhere to send it.
    ///
    /// Silently doing nothing is the one behaviour ruled out: a send button that
    /// swallows the message is indistinguishable from a slow network, and the
    /// user retypes. When the backend is missing, the reason is surfaced.
    func submit(_ text: String) {
        guard let backend else {
            // The `??` fallback is expected to be unreachable once `load()` has
            // run: `resolveBackend` sets a reason on all three of its failure
            // branches. Keep it anyway — this is not dead code to tidy away.
            //
            // What it buys is not coverage, it is the *shape of the failure* if
            // that invariant ever breaks. Nothing in the type system holds it:
            // a fourth branch in `resolveBackend`, or an early return, would
            // silently leave `backend == nil` with no reason set. With this
            // line, that regression surfaces as one more sentence on screen.
            // Without it, the send button simply stops working — which is
            // indistinguishable from a slow network, so the user retypes rather
            // than learning that no agent is attached.
            sendBlockedReason = sendBlockedReason
                ?? String(localized: "This conversation has no agent to send to.")
            return
        }
        send(text, using: service, to: backend)
    }

    /// Projects a session snapshot into what the two views render.
    ///
    /// Every field the views need is a value type by the time it leaves here —
    /// `LocalisUI` never sees a `Session`, a repository, or a service.
    private func apply(_ session: Session) {
        self.session = session
        messages = session.messages.map(MessageState.make(from:))
        composer = ComposerState.make(from: session)
    }

    /// Sends `text` and applies each streamed snapshot as it arrives.
    ///
    /// The stream yields complete `Session` values, so this re-projects rather
    /// than mutating anything in place.
    func send(_ text: String, using service: ChatService, to backend: AgentBackend) {
        guard let session else { return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                let stream = try await service.send(prompt: text, in: session, to: backend)
                for try await snapshot in stream {
                    self?.apply(snapshot)
                }
            } catch {
                // The transcript keeps whatever already arrived; only the
                // reason for stopping is new information.
                self?.loadError = (error as? LocalisError)?.userMessage
                    ?? "The reply stopped early."
            }
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }
}

struct SessionDetailView: View {
    @Environment(\.theme) private var theme

    private let repository: any SessionRepository
    private let sessionID: UUID
    /// Built once per view rather than per send: `ChatService` is an actor, and
    /// a fresh one per tap would serialise nothing and lose any in-flight turn.
    private let service: ChatService

    @State private var model: SessionDetailModel?
    @State private var draft: String = ""

    init(repository: any SessionRepository, sessionID: UUID) {
        self.repository = repository
        self.sessionID = sessionID
        // Milestone A's one fake. Everything under it — the session, the
        // backend, the persistence, the streaming loop — is the real thing;
        // only the far end is `EchoTransport`. Milestone B replaces this line
        // with a `BridgeClient` and deletes the file.
        self.service = ChatService(transport: EchoTransport(), repository: repository)
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task {
            let model = model ?? SessionDetailModel(
                repository: repository, sessionID: sessionID, service: service
            )
            self.model = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: SessionDetailModel) -> some View {
        if let loadError = model.loadError {
            ContentUnavailableView(
                "Couldn't open this session",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            VStack(spacing: 0) {
                // The fake announces itself above the transcript, not buried
                // under it. A screenshot of this screen has to carry the fact
                // that no Mac is connected, because screenshots travel further
                // than the code does and a convincing-looking conversation is
                // exactly what would be believed.
                StatusPill(EchoTransport.displayLabel, tone: .warning)
                    .padding(.horizontal, Space.cardPadding)
                    .padding(.bottom, 8)

                TranscriptView(messages: model.messages)

                // Why the backend is unroutable, when the session's own status
                // would have let it send. `ComposerState.blockedReason` cannot
                // carry this: it is derived from the session alone and knows
                // nothing about whether the agent was found.
                if let reason = model.sendBlockedReason {
                    StatusPill(reason, tone: .danger)
                        .padding(.horizontal, Space.cardPadding)
                        .padding(.bottom, 8)
                }

                if let composer = model.composer {
                    ComposerView(
                        state: composer,
                        draft: $draft,
                        onSend: { text in
                            model.submit(text)
                            // Cleared here rather than in the model: the draft
                            // is this view's state, and a model that reached
                            // back into it would own a field it cannot see.
                            draft = ""
                        },
                        onStop: { model.cancelStream() }
                    )
                }
            }
            .background(theme.neutrals.bg)
        }
    }
}
