import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// The chat screen builds its far end from the machine the conversation names.
///
/// **The gap this suite exists for.** Until milestone B `SessionDetailModel`
/// took a finished `ChatService` from its caller, and the caller built one over
/// `EchoTransport` — a fake that lived in the app target and answered every
/// question with success. Every test about the chat screen was therefore a test
/// about a transport that could not fail, and the two things that decide
/// whether a real send is even possible — *which* machine, and whether that
/// machine is connectable — were not on the path at all.
///
/// **What is checkable here and what is not.** Nothing here proves a byte
/// leaves the device; `BridgeTransport.factory` builds a real `BridgeClient` and
/// only a Mac on the network can answer it. What *is* checkable is everything
/// upstream of that call, and it is where the mistakes are: the host is read
/// through `HostAssembly` so the Keychain pin is reattached, the host handed to
/// the factory is the session's own, and a machine that cannot be connected to
/// gets a sentence naming its actual state rather than a client that fails
/// later with the wrong story.
///
/// **Why `canConnect` is enforced here rather than left to the transport.** A
/// `BridgeClient` built for an unpaired machine does fail — with `.unauthorized`,
/// whose wording is "This Mac no longer accepts this device". Every word of that
/// is false about a machine the user never paired, and it sends them to inspect
/// a pairing that was never made. `HostListModel.refreshReachability` makes the
/// same refusal for the same reason.
@Suite("The chat screen's transport is built for its own machine")
struct ChatTransportWiringTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Locked: Error {}

    /// A Keychain stand-in. Read-only: this suite never removes a credential.
    private struct Pins: PinReading {
        var pins: [HostID: SPKIHash] = [:]
        var failure: (any Error)?

        func pin(for host: HostID) throws -> SPKIHash? {
            if let failure { throw failure }
            return pins[host]
        }
    }

    /// Records which host the factory was asked to build a transport for.
    ///
    /// A class with a lock rather than an actor: the factory is a synchronous
    /// `@Sendable` closure, so it cannot await, and the test reads the record
    /// afterwards from a different isolation.
    private final class FactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _hosts: [LocalisHost] = []

        var hosts: [LocalisHost] {
            lock.withLock { _hosts }
        }

        func record(_ host: LocalisHost) {
            lock.withLock { _hosts.append(host) }
        }
    }

    private static func session(host: HostID, backendID: String = "claude") -> Session {
        Session(
            id: UUID(),
            hostID: host,
            backendID: backendID,
            title: "Refactor TransportKit",
            messages: [
                Message(id: UUID(), role: .user, text: "still here", createdAt: t0)
            ],
            createdAt: t0,
            updatedAt: t0,
            status: .idle
        )
    }

    /// A machine on file, in whatever pairing state the test is about.
    ///
    /// `pinnedSPKI` is deliberately never passed: `save(_ host:)` strips it on
    /// every repository, so a fixture that set it here would be describing a
    /// state the store cannot hold, and the test would pass on a fiction. The
    /// pin arrives through `Pins`, which is the join production uses.
    private static func host(
        _ state: HostPairingState = .paired,
        name: String = "Studio"
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: "\(name.lowercased()).local", port: 8443),
            bridgeID: "bridge-\(name.lowercased())",
            pairingState: state
        )
    }

    private static func seeded(
        host: LocalisHost,
        backend: AgentBackend = AgentBackend(id: "claude", displayName: "Studio Claude")
    ) async throws -> (repository: InMemorySessionRepository, session: Session) {
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        try await repository.save(backend, on: host.id)
        let session = Self.session(host: host.id)
        try await repository.create(session)
        return (repository, session)
    }

    // MARK: - Which machine

    /// The factory is asked for the session's own machine, not for any other.
    ///
    /// **Two hosts, because one proves nothing.** With a single machine on file
    /// an implementation that took "the first host" — or the only one — would
    /// pass, and that is not a hypothetical shape: `SessionListModel` shipped a
    /// bug of exactly this family, resolving backends correctly per host and
    /// then flattening them into a list with no host in it, so a row wore the
    /// other machine's name. The failure is silent by construction: the reply
    /// arrives looking entirely normal, from a different computer.
    @Test("the transport is built for the machine the conversation names")
    func transportSeesTheSessionsOwnHost() async throws {
        let studio = Self.host(name: "Studio")
        let laptop = Self.host(name: "Laptop")
        let repository = InMemorySessionRepository()
        try await repository.save(studio)
        try await repository.save(laptop)
        try await repository.save(
            AgentBackend(id: "claude", displayName: "Laptop Claude"), on: laptop.id
        )
        try await repository.save(
            AgentBackend(id: "claude", displayName: "Studio Claude"), on: studio.id
        )
        let session = Self.session(host: laptop.id)
        try await repository.create(session)

        let log = FactoryLog()
        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(pins: [
                studio.id: SPKIHash(base64: "STUDIO="),
                laptop.id: SPKIHash(base64: "LAPTOP="),
            ]),
            makeTransport: { host in
                log.record(host)
                return EchoTransport(chunkDelay: .zero)
            }
        )
        await model.load()

        #expect(log.hosts.map(\.id) == [laptop.id])
        // And nothing blocked the send path on the way — otherwise this would
        // also pass on a build that asked for the right host and then refused
        // to use it.
        #expect(await model.sendBlockedReason == nil)
    }

    /// The host reaches the factory with its pin attached (FR-028).
    ///
    /// **This is the whole reason `HostAssembly` is on this path.** The store
    /// has no pin column — both repositories strip it on save — so a record read
    /// straight from the repository always has `pinnedSPKI == nil` and
    /// `canConnect == false`. A `BridgeClient` built from that host refuses
    /// every connection, because `PinnedHTTP` treats a nil pin as "no
    /// permission" rather than as trust on first use. So the bug this pins down
    /// is not a compile error and not a crash: every conversation on a genuinely
    /// paired Mac fails at the TLS handshake, and reads on screen as the Mac
    /// being offline.
    ///
    /// Asserted on the pin's presence rather than on its value's secrecy: the
    /// value is a public SPKI digest, not a token, and `HostAssembly` is the
    /// type that owns "who may see a pin".
    @Test("the host handed to the factory carries the Keychain pin, not the bare store record")
    func factoryReceivesThePinnedHost() async throws {
        let host = Self.host()
        let (repository, session) = try await Self.seeded(host: host)

        // The store's own answer, for contrast: this is what the factory would
        // receive if the join were skipped.
        let asStored = try #require(try await repository.host(id: host.id))
        #expect(asStored.pinnedSPKI == nil, "precondition: the store does not keep pins")
        #expect(!asStored.canConnect, "precondition: and so cannot answer this on its own")

        let log = FactoryLog()
        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(pins: [host.id: SPKIHash(base64: "AAA=")]),
            makeTransport: { host in
                log.record(host)
                return EchoTransport(chunkDelay: .zero)
            }
        )
        await model.load()

        let seen = try #require(log.hosts.first)
        #expect(seen.pinnedSPKI == SPKIHash(base64: "AAA="))
        #expect(seen.canConnect)
    }

    // MARK: - Machines that cannot be connected to

    /// A conversation whose machine is no longer on this device.
    ///
    /// Both halves asserted, because either alone is a different and wrong
    /// product: a blocked composer with the transcript hidden loses history the
    /// user still owns (FR-036), and a readable transcript with an open composer
    /// accepts a message that has nowhere to go.
    @Test("a conversation whose Mac is gone stays readable and says why it can't send")
    func missingHostKeepsTheTranscript() async throws {
        let repository = InMemorySessionRepository()
        // No `save(_ host:)`: the session names a machine with no record, which
        // is what a removed Mac leaves behind (FR-027 keeps the conversation).
        let session = Self.session(host: HostID())
        try await repository.create(session)
        try await repository.save(
            AgentBackend(id: "claude", displayName: "Claude"), on: session.hostID
        )

        let log = FactoryLog()
        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(),
            makeTransport: { host in
                log.record(host)
                return EchoTransport(chunkDelay: .zero)
            }
        )
        await model.load()

        #expect(await model.messages.map(\.text) == ["still here"])
        #expect(await model.loadError == nil)
        #expect(await model.sendBlockedReason != nil)
        // No transport was built. Asserted separately from the sentence: an
        // implementation that reported the reason *and* went on to construct a
        // client for a machine it just said was missing would satisfy every
        // assertion above.
        #expect(log.hosts.isEmpty)
    }

    /// A paired machine whose pin did not come back — a restored device backup.
    ///
    /// The store travels in an iCloud backup and the Keychain does not, so this
    /// is the ordinary state of a reinstalled app, not an exotic one. The
    /// sentence is the one the host list already uses for it (#51): two screens
    /// reaching the same situation must not produce two different texts about
    /// it, or the user is left deciding which one is about their problem.
    @Test("a paired Mac with no pin on this device says the pairing is missing")
    func pairedWithoutPinIsNamedAsMissingCredential() async throws {
        let host = Self.host(.paired)
        let (repository, session) = try await Self.seeded(host: host)

        let log = FactoryLog()
        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            // Empty on purpose: paired on file, nothing in the Keychain.
            credentials: Pins(),
            makeTransport: { host in
                log.record(host)
                return EchoTransport(chunkDelay: .zero)
            }
        )
        await model.load()

        #expect(await model.sendBlockedReason == HostReachability.missingCredentialMessage)
        #expect(log.hosts.isEmpty)
        // Reading survives it (FR-036).
        #expect(await model.messages.map(\.text) == ["still here"])
    }

    /// A machine that was never paired is not described as one that stopped
    /// accepting this device.
    ///
    /// **Asserted as a difference, not as an equality.** Pinning the exact
    /// string would fail on a rewording that fixed nothing, while still missing
    /// the failure that matters: reusing a sentence that sends the user to the
    /// wrong place. `unauthorized`'s wording is the specific wrong answer here —
    /// it is what a `BridgeClient` built for this host would eventually produce,
    /// and it claims a pairing existed and was withdrawn.
    @Test("a Mac that was never paired is not told it stopped accepting this device")
    func unpairedHostIsNotCalledUnauthorized() async throws {
        let host = Self.host(.discovered)
        let (repository, session) = try await Self.seeded(host: host)

        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(pins: [host.id: SPKIHash(base64: "AAA=")]),
            makeTransport: { _ in EchoTransport(chunkDelay: .zero) }
        )
        await model.load()

        let reason = try #require(await model.sendBlockedReason)
        #expect(reason != HostUnreachableReason.unauthorized.userMessage)
        #expect(reason != HostReachability.missingCredentialMessage)
        #expect(await model.composer?.canSend == false)
    }

    /// A machine whose certificate changed keeps that sentence, and it must not
    /// be softened into an ordinary re-pair.
    ///
    /// Constitution V allows no override. "Pair again" alone would be advice to
    /// pin whatever certificate is being presented *now*, which is precisely the
    /// substitution the pin exists to refuse — so this state gets the wording
    /// that names the identity change.
    @Test("a Mac whose certificate changed says so rather than asking for a plain re-pair")
    func certificateChangeKeepsItsOwnSentence() async throws {
        let host = Self.host(.certificateChanged)
        let (repository, session) = try await Self.seeded(host: host)

        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(pins: [host.id: SPKIHash(base64: "AAA=")]),
            makeTransport: { _ in EchoTransport(chunkDelay: .zero) }
        )
        await model.load()

        #expect(
            await model.sendBlockedReason == HostUnreachableReason.certificateRejected.userMessage
        )
    }

    // MARK: - The Keychain refusing to answer

    /// A locked Keychain is not an unpaired machine, and must not be reported as
    /// one.
    ///
    /// **The wrong answer here is destructive, which is why this has its own
    /// test.** "Pair this Mac again" is the action that *overwrites* the pin we
    /// just failed to read. `HostAssembly.joined` refuses to swallow the error
    /// for the same reason, and this is the assertion that the refusal survives
    /// the trip up to the screen instead of being flattened into the missing-
    /// credential sentence one branch over.
    @Test("a Keychain that won't answer is not reported as a missing pairing")
    func keychainFailureIsNotCalledUnpaired() async throws {
        let host = Self.host(.paired)
        let (repository, session) = try await Self.seeded(host: host)

        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(failure: Locked()),
            makeTransport: { _ in EchoTransport(chunkDelay: .zero) }
        )
        await model.load()

        let reason = try #require(await model.sendBlockedReason)
        #expect(reason != HostReachability.missingCredentialMessage)
        // And the failure is not silent: the user is told something rather than
        // being handed a composer that stops working with no sentence.
        #expect(await model.composer?.canSend == false)
        // The transcript is untouched — a Keychain that would not answer costs
        // the send path only (FR-036).
        #expect(await model.messages.map(\.text) == ["still here"])
    }

    // MARK: - The send path

    /// Submitting into a conversation with no transport keeps the reason it
    /// already had, and does not take the message.
    ///
    /// **What this measures, and what it cannot.** `submit` has a `guard let
    /// service` whose `??` fallback writes its own sentence. That fallback is
    /// unreachable after a completed `load()` — `openService` sets a reason on
    /// all four of its branches — which was verified by mutation rather than
    /// assumed: replacing the whole guard with `guard let service else
    /// { return }` leaves **every one of the 74 tests green**, this one
    /// included. It is the same shape the production comment describes for the
    /// `backend` guard one line above it: a tripwire for an invariant break, not
    /// a live path, and no test here can redden it without a way to reach
    /// `submit` with a resolved backend and no service and no reason — a state
    /// the model has no construction for.
    ///
    /// So the claim is narrowed to the two things that *are* live. First, the
    /// message is not taken: silence is the failure mode that matters, because a
    /// send button that swallows a message is indistinguishable from a slow
    /// reply and the user retypes. Second, the sentence the user is left with is
    /// still the specific one — a `submit` that overwrote it with its own
    /// vaguer wording would replace "your pairing is missing, pair again" with
    /// "no Mac to send to", which names no action. That overwrite *does* redden
    /// this test.
    @Test("submitting with no transport keeps the specific reason and does not take the message")
    func submitWithoutTransportSurfacesReason() async throws {
        let host = Self.host(.paired)
        let (repository, session) = try await Self.seeded(host: host)

        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            credentials: Pins(),
            makeTransport: { _ in EchoTransport(chunkDelay: .zero) }
        )
        await model.load()
        // The backend resolved: this is not the no-agent branch.
        #expect(await model.backend != nil)

        await model.submit("does this go anywhere")
        await model.awaitStream()

        #expect(await model.sendBlockedReason == HostReachability.missingCredentialMessage)
        // The dropped message must not appear in the transcript — showing it
        // would claim it was sent. Nor may it reach the store: a message
        // persisted by a send that never happened comes back after the next
        // relaunch looking delivered.
        #expect(await model.messages.map(\.text) == ["still here"])
        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.messages.map(\.text) == ["still here"])
    }
}
