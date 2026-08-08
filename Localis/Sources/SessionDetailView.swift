import ChatService
import DesignKit
import LocalisModels
import LocalisUI
import SessionStore
import SwiftUI
import TransportKit

/// One session: its transcript, and the composer under it.
///
/// Sending goes through `ChatService`, never through the repository directly —
/// the service is the only thing that knows the *order* of persist-then-stream,
/// and a view that saved its own message would write half a turn.
///
/// **The far end is a real `BridgeClient` as of milestone B**, built for this
/// conversation's own machine. Nothing on the path is a stand-in any more: the
/// session and its backend come from the store, the host comes from
/// `HostAssembly` with its Keychain pin reattached, the turn is persisted before
/// it streams, and it is still there after a relaunch.
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
    /// Rejoins a stored host record with its Keychain pin.
    ///
    /// **The session's host must come through here rather than off the
    /// repository.** The store has no pin column, so a record read straight from
    /// it always has `canConnect == false` and `pinnedSPKI == nil` — and a
    /// `BridgeClient` built from that host refuses every connection, because
    /// `PinnedHTTP` treats a nil pin as "no permission" rather than as trust on
    /// first use. Every conversation on a genuinely paired Mac would then fail
    /// at the TLS handshake, which reads on screen as the Mac being offline.
    /// This is the one join that reattaches the pin and it is meant to be the
    /// only one (`HostAssembly`).
    private let assembly: HostAssembly
    /// Builds the transport for the machine this conversation lives on.
    ///
    /// Injected rather than constructed for the reason `HostProbing` is: a model
    /// that built its own `BridgeClient` could be exercised only against a real
    /// Mac, so "a signed-out agent says so" and "a revoked token unpairs the
    /// machine" would be checkable by hand and never in a suite.
    private let makeTransport: ChatTransportFactory
    /// Built in `load()`, not in `init` — see `service(for:)`.
    private var service: ChatService?
    /// Applies whatever a refusal implies about the machine's pairing.
    ///
    /// Held here because this is where a 401 actually lands: the transport maps
    /// it to a `LocalisError` and the stream throws it, and until now the only
    /// consequence was a sentence on screen. A Mac that revoked this device
    /// went on being listed as "Paired", with its pin still in the Keychain.
    private let revocation: HostRevocation
    private var session: Session?
    private var streamTask: Task<Void, Never>?

    /// - Parameters:
    ///   - credentials: reads pins for the host join. Defaults to the real
    ///     Keychain; a test substitutes one so the suite does not go red for
    ///     Keychain reasons unrelated to its subject (`PinReading`).
    ///   - makeTransport: defaults to a real `BridgeClient` per host. Tests pass
    ///     a fake — that substitution is the only thing this parameter is for,
    ///     and it replaces the *whole* transport, so everything downstream of it
    ///     is the same code production runs.
    init(
        repository: any SessionRepository,
        sessionID: UUID,
        credentials: any PinReading = HostCredentialStore(),
        makeTransport: @escaping ChatTransportFactory = BridgeTransport.factory,
        revocation: HostRevocation? = nil
    ) {
        self.repository = repository
        self.sessionID = sessionID
        self.assembly = HostAssembly(repository: repository, credentials: credentials)
        self.makeTransport = makeTransport
        self.revocation = revocation ?? HostRevocation(repository: repository)
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
            // After `resolveBackend`, so that when both fail the machine-level
            // sentence is the one left standing. "This Mac isn't on this device
            // any more" and "this conversation's agent isn't on this Mac" name
            // two different missing things and two different fixes, and the
            // first subsumes the second — an agent cannot be found on a machine
            // that is not there. Ordering these the other way round would leave
            // the user looking for a missing agent on a Mac they no longer have.
            await openService(for: session)
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

    /// Builds the `ChatService` for this conversation's own machine.
    ///
    /// **Why this cannot happen in `init`.** The transport is per host — one
    /// token, one pinned certificate, one endpoint (`BridgeClient`) — and the
    /// host is `session.hostID`, which is not known until the session has been
    /// read. A service built in `init` could only be built for *some* host, and
    /// the only ones available there are none and a guess.
    ///
    /// **Failure leaves `service` nil rather than throwing.** Two failures land
    /// here and neither is a reason to hide the transcript (FR-036): a host row
    /// that is gone, and a Keychain that could not be read. Both cost the send
    /// path only, which is what `sendBlockedReason` is for.
    private func openService(for session: Session) async {
        do {
            guard let host = try await assembly.host(id: session.hostID) else {
                // No record for the machine this conversation names. The
                // conversation is still the user's; there is simply nothing to
                // send it to. Worded about the Mac rather than about the agent —
                // `resolveBackend`'s sentence names an agent that is missing from
                // a machine that is present, which is a different situation and a
                // different fix.
                service = nil
                sendBlockedReason = String(
                    localized: "This conversation's Mac isn't on this device any more."
                )
                return
            }
            // The same refusal `BridgeHostProbe` makes, and for a stronger
            // reason here: a `BridgeClient` built for an unconnectable host is
            // not merely useless, it fails in a way that describes the wrong
            // problem. With no pin `PinnedHTTP` rejects the handshake, and with
            // no token `request` throws `.unauthorized`, whose wording is "This
            // Mac no longer accepts this device" — every word of which is false
            // about a machine the user has not paired yet, and it sends them to
            // inspect a pairing that was never made.
            guard host.canConnect else {
                service = nil
                sendBlockedReason = Self.unconnectableReason(for: host)
                return
            }
            service = ChatService(transport: try makeTransport(host), repository: repository)
        } catch {
            // A Keychain that would not answer is not a machine that is
            // unpaired, and must not be reported as one — re-pairing is exactly
            // the operation that overwrites the pin we failed to read
            // (`HostAssembly.joined`). So the error is surfaced with its own
            // words rather than swallowed into the sentence above.
            service = nil
            sendBlockedReason = (error as? LocalisError)?.userMessage
                ?? String(localized: "Couldn't reach this conversation's Mac on this device.")
        }
    }

    /// Why a machine on file still cannot be connected to.
    ///
    /// Three sentences because there are three different things for the user to
    /// do, and the sentences are borrowed rather than written: the same
    /// situation reached from the host list and from here must not produce two
    /// different texts about it.
    ///
    /// Exhaustive with no `default`, so a new pairing state has to be given
    /// words rather than inheriting whichever case happened to be last.
    private static func unconnectableReason(for host: LocalisHost) -> String {
        switch host.pairingState {
        case .certificateChanged:
            // Constitution V: named, and never worded as something a plain
            // re-pair fixes — re-pairing would pin whatever certificate is being
            // presented now, which is the attack the pin exists to stop.
            return HostUnreachableReason.certificateRejected.userMessage
        case .paired:
            // Paired with no pin: a restored device backup carries the store but
            // not the Keychain. `HostReachability.missingCredentialMessage` is
            // the sentence written for exactly this state, and the host list
            // already shows it (#51).
            return HostReachability.missingCredentialMessage
        case .discovered, .pairing, .revoked:
            // Nothing was ever established with this machine, or it was undone.
            // Not "isn't answering": no request was made, and blaming the
            // network sends the user to check a Wi-Fi connection that is fine.
            return String(
                localized: "This Mac isn't paired. Pair it again to continue this conversation."
            )
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
    ///
    /// **This is where the host's own answer about the backend lands (#41).**
    /// `resolveBackend` read the backend from storage, which flattens
    /// `availability` to `.available` because no disk can know whether an agent
    /// is signed in right now. That flattening is only safe because this call
    /// supplies the fresh value; before it existed, a signed-out agent got an
    /// open composer and failed at the far end.
    private func reconnectIfPossible() async {
        // No service means the machine could not be reached at all — no host
        // record, no pin, or a Keychain that would not answer. `openService`
        // has already put that sentence on screen, and asking a transport that
        // does not exist is not a thing to report twice.
        guard let session, let backend, let service else { return }

        let (reconnected, description) = await service.reopen(session, to: backend)
        apply(describing: description)
        // Re-projected through the same path as every other snapshot, so the
        // composer is derived from the session rather than being switched on
        // here. A local `canSend = true` would be a second opinion, and the two
        // would drift.
        apply(reconnected)
    }

    /// Records what the host said about this conversation's agent.
    ///
    /// Three answers and three sentences, because they are three different
    /// things for the user to do. Collapsing them into "unavailable" would be
    /// the same loss this edge exists to undo, one layer further up.
    private func apply(describing description: BackendDescription) {
        switch description {
        case .listed(let live):
            // The live value replaces the stored one, so anything reading
            // `backend` downstream sees what the Mac says rather than what the
            // disk kept.
            backend = live
            sendBlockedReason = live.isAvailable
                ? nil
                : String(localized: "This agent isn't signed in on the Mac.")

        case .absent:
            // The Mac answered and no longer lists this agent. Distinct from a
            // missing host row, which `resolveBackend` words as "isn't on this
            // Mac any more" — that one is about pairing, this one is about an
            // agent that was removed from a machine still paired.
            sendBlockedReason = String(
                localized: "This Mac no longer offers this agent."
            )

        case .unknown:
            // The host could not be asked, so it said nothing about the agent —
            // and this must not be reported as signed out. Waiting fixes a
            // sleeping Mac and never fixes a signed-out agent; naming the wrong
            // one sends the user to sign in on a machine that is off.
            //
            // Deliberately leaves `sendBlockedReason` as `resolveBackend` left
            // it. The composer's own `blockedReason` already says the link is
            // down, and the session's status is unchanged, so nothing here is
            // claiming the link works.
            break
        }
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
            //
            // **`match` comes from storage, where this is always `.available`**,
            // deliberately — a week-old `not_logged_in` must not grey out an
            // agent the user has since signed into (`SessionRepository.restored`,
            // and `availabilityIsNotRestored` pins it). So the sentence below is
            // not reachable from this value alone, and never was.
            //
            // The live answer arrives in `reconnectIfPossible`, which asks the
            // host and overwrites both fields (#41). Kept here rather than
            // deleted: this runs first and the transcript renders before the
            // refresh returns, so without it a signed-out agent would show an
            // open composer for as long as the request is in flight.
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
        // Same shape, one layer out: the backend was found and the machine it
        // lives on could not be opened. `openService` sets a reason on all four
        // of its failure branches, so the `??` is the same tripwire as above and
        // not an expected path. Silently returning here is the one behaviour
        // ruled out — a send button that swallows the message reads as a slow
        // network, and the user retypes.
        guard let service else {
            sendBlockedReason = sendBlockedReason
                ?? String(localized: "This conversation has no Mac to send to.")
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
                // A refusal can mean more than "this turn failed": a revoked
                // token means this device is no longer paired with that Mac,
                // and saying so only in a sentence would leave the host list
                // claiming otherwise and the pin sitting in the Keychain.
                await self?.applyPairingConsequence(of: error, host: session.hostID)
            }
        }
    }

    /// Lets a transport failure change the machine's pairing, when it implies
    /// one.
    ///
    /// **Failures here are deliberately swallowed, and this is the one place in
    /// the type where that is right.** The user has already been told the turn
    /// failed. A second error about the Keychain, raised while they are looking
    /// at a reply that stopped, explains nothing they can act on — and the
    /// original message is the one that matters. The record simply stays
    /// `.paired`, which is what it was before.
    private func applyPairingConsequence(of error: any Error, host: HostID) async {
        guard let error = error as? LocalisError else { return }
        try? await revocation.apply(error, to: host)
    }

    /// Waits for the in-flight stream, if any. Test support: the stream runs in
    /// a detached task, so an assertion made straight after `submit` would race
    /// it.
    func awaitStream() async {
        await streamTask?.value
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

    @State private var model: SessionDetailModel?
    @State private var draft: String = ""

    init(repository: any SessionRepository, sessionID: UUID) {
        self.repository = repository
        self.sessionID = sessionID
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
            // The model builds its own `ChatService` inside `load()`, once the
            // session names the machine it belongs to. It cannot be built here:
            // a `BridgeClient` is per host — one token, one pinned certificate,
            // one endpoint — and this view knows only a session id.
            let model = model ?? SessionDetailModel(
                repository: repository, sessionID: sessionID
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
