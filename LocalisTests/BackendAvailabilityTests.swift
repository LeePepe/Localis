import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// A transport that reports whatever this test says the host reports (#41).
///
/// `EchoTransport`, the fixture the assembly suites stream through, answers
/// `.listed` with the backend unchanged and `.reachable` unconditionally —
/// right for a fake with no host behind it and useless here: the entire subject
/// of this suite is what the app does with the *other* answers.
private actor DescribingTransport: AgentTransport {
    private let description: BackendDescription
    private let reachability: HostReachability
    private(set) var refreshCount = 0

    /// - Parameters:
    ///   - description: what the host says about the backend. Three cases, not
    ///     an `AgentBackend?`: "the Mac no longer lists this agent" and "the Mac
    ///     never answered" are opposite situations for the user, and the
    ///     optional spelling folds them into one `nil`.
    ///   - reachability: whether the host answers at all. Defaulted rather than
    ///     derived from `description`, because deriving it would make one stub
    ///     drive both of `reconnect`'s guards — a build that dropped the
    ///     availability check entirely would still be blocked by the probe, and
    ///     this suite would report the right outcome for the wrong reason.
    ///
    ///     The default pairs each answer with the reachability production can
    ///     actually produce alongside it: `BridgeClient` derives both from one
    ///     `/v1/models` round trip, so a host that answered `.listed`/`.absent`
    ///     is by construction reachable, and one that yielded `.unknown` is not.
    init(description: BackendDescription, reachability: HostReachability? = nil) {
        self.description = description
        self.reachability = reachability ?? {
            switch description {
            case .listed, .absent: return .reachable
            case .unknown: return .unreachable(reason: .offline)
            }
        }()
    }

    func send(_ request: TurnRequest) async throws -> TurnStream {
        // No test here starts a turn. Recorded rather than silently returning an
        // empty stream: a no-op would make "wrongly started a turn" look
        // identical to "did nothing", which is one of the two states this suite
        // distinguishes.
        Issue.record("resolving availability must not start a turn")
        return TurnStream(turnID: nil, events: AsyncThrowingStream { $0.finish() })
    }

    func probe(_ backend: AgentBackend) async -> HostReachability {
        reachability
    }

    /// **Ignores the `backend` argument on purpose.** In production it always
    /// arrives from storage, where both repositories flatten `availability` to
    /// `.available` on read; a fake that echoed it back would answer "whatever
    /// you passed in" and stay green against an implementation that read the
    /// stored value rather than the host's — the exact bug #41 fixes.
    func refresh(_ backend: AgentBackend) async -> BackendDescription {
        refreshCount += 1
        return description
    }
}

/// The host's answer about a backend must reach the screen (#41).
///
/// **The gap.** `BackendCatalog` decodes `.unavailable(reason:)` off `/v1/models`
/// correctly, and both stores drop `availability` on read — also correctly, since
/// no disk can know whether a backend is signed in *right now*, and a week-old
/// `not_logged_in` must not grey out an agent the user has since signed into.
///
/// Dropping a stale negative is only safe if something supplies a fresh one.
/// Nothing did: the decoded value's only consumer was `BridgeClient.probe`,
/// which read `isAvailable` into a bool and discarded the backend. So every
/// `AgentBackend` a screen could reach came from storage saying `.available`,
/// and `SessionDetailView`'s "isn't signed in" branch was unreachable — the app
/// would offer a composer for an agent that cannot answer, then fail at the far
/// end. That is the accept-then-fail shape FR-053 rules out.
///
/// **What this suite asserts is the user-visible half**, not the plumbing: the
/// sentence on screen. A test that checked `model.backend?.isAvailable` would
/// pass against a build that carried the value and never rendered it.
@Suite("The host's answer about a backend reaches the screen")
struct BackendAvailabilityTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Writes through one repository and reads through another over the same
    /// container, the way a relaunch sees it — so nothing here is answered from
    /// an in-process cache that a real cold start would not have.
    private static func relaunching(
        _ write: (SwiftDataSessionRepository) async throws -> Void
    ) async throws -> SwiftDataSessionRepository {
        let container = try SessionStoreContainer.inMemory()
        try await write(SwiftDataSessionRepository(container: container))
        return SwiftDataSessionRepository(container: container)
    }

    /// A paired machine with one agent and one stored conversation.
    ///
    /// The backend is stored `.available` on purpose: storage cannot hold
    /// anything else (both repositories drop the field), so seeding a negative
    /// would be describing a state the app can never actually be in, and the
    /// test would be about a fixture rather than about the app.
    ///
    /// `pairingState: .paired` is what makes the host connectable once
    /// `AnyPin` reattaches a pin. Without it `SessionDetailModel` never builds a
    /// transport at all, `DescribingTransport` is never asked anything, and
    /// every test here would pass or fail on a pairing sentence rather than on
    /// the availability answer it names.
    private static func seed(
        into repository: SwiftDataSessionRepository
    ) async throws -> UUID {
        let host = LocalisHost(
            id: HostID(),
            displayName: "A paired Mac",
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            bridgeID: "bridge-abc",
            pairingState: .paired
        )
        try await repository.save(host)

        let backend = AgentBackend(id: "claude", displayName: "Claude Code")
        try await repository.save(backend, on: host.id)

        let session = Session(
            id: UUID(),
            hostID: host.id,
            backendID: backend.id,
            title: "Yesterday's conversation",
            messages: [],
            createdAt: t0,
            updatedAt: t0,
            status: .idle
        )
        try await repository.create(session)

        return session.id
    }

    /// A Keychain stand-in with a pin for every machine.
    ///
    /// The store strips pins on save, so a host read back has
    /// `canConnect == false` and no transport is built for it at all. This suite
    /// is about the answer a *connected* host gives, so the pin has to come from
    /// somewhere; `HostAssemblyTests` owns the question of which machines have
    /// one.
    private struct AnyPin: PinReading {
        func pin(for host: HostID) throws -> SPKIHash? { SPKIHash(base64: "AAA=") }
    }

    /// The stub is handed over as the whole transport, not as a service built
    /// around one.
    ///
    /// **This is the seam milestone B added, and using it is the point.** The
    /// model builds its own `ChatService` during `load()`, because the transport
    /// is per host and the host is not known until the session has been read
    /// (`SessionDetailModel.openService`). A helper that still constructed the
    /// service here would be handing the model something it no longer accepts —
    /// and, worse, would bypass the host join, so a suite about what the *host*
    /// says would never have touched a host record.
    private static func model(
        repository: any SessionRepository,
        sessionID: UUID,
        transport: DescribingTransport
    ) async -> SessionDetailModel {
        await SessionDetailModel(
            repository: repository,
            sessionID: sessionID,
            credentials: AnyPin(),
            makeTransport: { _ in transport }
        )
    }

    /// The value the whole edge exists to carry.
    ///
    /// Asserted on the sentence rather than on `backend?.isAvailable`: carrying
    /// the value into the model and never rendering it would leave the user with
    /// exactly the screen they had before, and that version of the bug would
    /// pass a check written against the model's own field.
    @Test("a signed-out agent says so instead of offering a composer")
    func signedOutBackendIsNamedOnScreen() async throws {
        var sessionID: UUID?
        let repository = try await Self.relaunching { sessionID = try await Self.seed(into: $0) }
        let id = try #require(sessionID)

        let signedOut = AgentBackend(
            id: "claude",
            displayName: "Claude Code",
            availability: .unavailable(reason: "not_logged_in")
        )
        let model = await Self.model(
            repository: repository,
            sessionID: id,
            transport: DescribingTransport(description: .listed(signedOut))
        )
        await model.load()

        // Reading is never gated (FR-036) — a signed-out agent costs the send
        // path, not the transcript.
        await #expect(model.loadError == nil)
        await #expect(model.composer != nil)

        await #expect(model.sendBlockedReason != nil)
        await #expect(model.composer?.canSend == false)
    }

    /// The other direction, and it is not redundant.
    ///
    /// The cheapest way to pass the test above is to block sending whenever a
    /// refresh happens at all. That would also block every signed-in agent —
    /// the deadlock #25 fixed, reintroduced one layer up — and only an assertion
    /// on the available case can see it.
    @Test("a signed-in agent is still sendable")
    func availableBackendStaysSendable() async throws {
        var sessionID: UUID?
        let repository = try await Self.relaunching { sessionID = try await Self.seed(into: $0) }
        let id = try #require(sessionID)

        let signedIn = AgentBackend(id: "claude", displayName: "Claude Code")
        let model = await Self.model(
            repository: repository,
            sessionID: id,
            transport: DescribingTransport(description: .listed(signedIn))
        )
        await model.load()

        await #expect(model.sendBlockedReason == nil)
        await #expect(model.composer?.canSend ?? false)
    }

    /// A host that cannot be asked must not be reported as signed out.
    ///
    /// "The Mac is asleep" and "the agent is signed out" call for different
    /// actions — waiting fixes the first and never the second — and a refresh
    /// that returned no answer knows neither. Treating silence as unavailable
    /// would tell a user to go sign in on a machine that is simply off.
    ///
    /// The composer stays closed either way, so this is asserted on the
    /// *wording*: the two states differ only in what the sentence says.
    @Test("a host that cannot be reached is not reported as signed out")
    func unreachableHostIsNotCalledSignedOut() async throws {
        var sessionID: UUID?
        let repository = try await Self.relaunching { sessionID = try await Self.seed(into: $0) }
        let id = try #require(sessionID)

        let model = await Self.model(
            repository: repository,
            sessionID: id,
            transport: DescribingTransport(description: .unknown)
        )
        await model.load()

        let signedOutWording = String(localized: "This agent isn't signed in on the Mac.")
        await #expect(model.sendBlockedReason != signedOutWording)
    }

    /// The third answer, which the `AgentBackend?` spelling could not hold.
    ///
    /// A Mac that is up and no longer offers this agent is not a Mac that failed
    /// to answer, and the two need different sentences: this one is fixed by
    /// picking another agent or reinstalling that one, and never by waiting.
    /// Under an optional both arrived as `nil`, so whichever sentence was
    /// written would have been wrong half the time — the same collapse #34/#45
    /// undid one layer down.
    @Test("an agent the Mac no longer offers is not reported as unreachable")
    func absentBackendIsNotCalledUnreachable() async throws {
        var sessionID: UUID?
        let repository = try await Self.relaunching { sessionID = try await Self.seed(into: $0) }
        let id = try #require(sessionID)

        let transport = DescribingTransport(description: .absent)
        let model = await Self.model(repository: repository, sessionID: id, transport: transport)
        await model.load()

        // The transcript survives the agent (FR-036) — losing the agent costs
        // the send path, not what the user already read.
        await #expect(model.loadError == nil)
        await #expect(model.composer != nil)
        await #expect(model.composer?.canSend == false)

        // And the reason is this one, not either neighbour. Asserted as a
        // difference rather than an equality: pinning the exact string would
        // make this test fail on a wording change that fixed nothing, while
        // still not catching the failure that matters — reusing a sentence that
        // sends the user to do the wrong thing.
        let reason = try #require(await model.sendBlockedReason)
        #expect(reason != String(localized: "This agent isn't signed in on the Mac."))
        #expect(
            reason != String(localized: "This conversation's agent isn't on this Mac any more.")
        )
    }

    /// The host is asked exactly once per open.
    ///
    /// Not a performance note. `load()` runs on every tap into a conversation,
    /// and a second refresh would be a second `/v1/models` round trip whose
    /// answer can differ from the first — a sign-in landing between them leaves
    /// two truths on one screen, with no rule saying which wins. `BridgeClient`
    /// shares one request between `probe` and `refresh` for the same reason.
    ///
    /// The count is the whole assertion, so it is pinned on both sides: `>= 1`
    /// would miss the duplicate, and no assertion at all would let a build that
    /// stopped asking pass every other test here by falling back to the stored
    /// `.available`.
    @Test("the host is asked exactly once when a conversation is opened")
    func refreshHappensOnceOnOpen() async throws {
        var sessionID: UUID?
        let repository = try await Self.relaunching { sessionID = try await Self.seed(into: $0) }
        let id = try #require(sessionID)

        let transport = DescribingTransport(description: .listed(
            AgentBackend(
                id: "claude",
                displayName: "Claude Code",
                availability: .unavailable(reason: "not_logged_in")
            )
        ))
        let model = await Self.model(repository: repository, sessionID: id, transport: transport)
        await model.load()

        #expect(await transport.refreshCount == 1)
        await #expect(model.sendBlockedReason != nil)
    }
}
