import Foundation
import Testing

@testable import Localis

import ChatService
import LocalisModels
import SessionStore
import TransportKit

/// What a rejected token has to do to the machine that presented it.
///
/// **The gap this was written for.** A 401 travelled as far as
/// `BridgeClient.error(status:code:reason:)`, became a `LocalisError`, and every
/// consumer put its `userMessage` into a `String?` for display. Nothing wrote to
/// the store and nothing touched the Keychain — so the host list went on saying
/// "Paired" for a machine that refuses every request, and the pin stayed on disk
/// for a host the Mac had explicitly stopped trusting. The contract's acceptance
/// list asks for the opposite on all three counts (bridge-protocol.md :638,
/// :684, :686).
///
/// **Why the assertions are about residue rather than about the happy path.**
/// Getting the revoked host into `.revoked` is the easy half and a single wrong
/// line makes it pass. The half that goes wrong silently is everything the
/// operation must *not* disturb: the other machine's credentials, and the
/// user's conversations. Both are invisible in the UI at the moment it happens
/// and only surface later, as a machine that mysteriously needs re-pairing or a
/// history that is simply gone.
@Suite("A rejected token unpairs its own machine and nothing else")
struct HostRevocationTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A Keychain stand-in that records deletions.
    ///
    /// Writable where `HostAssemblyTests.FakeCredentials` is read-only: this
    /// suite's subject is the removal, so "was it asked to remove, and for
    /// which host" is the observation, not a detail.
    ///
    /// A class rather than a struct because the object under test holds it and
    /// the test has to see what happened to it afterwards. `@unchecked
    /// Sendable` with a lock rather than an actor so the fake can satisfy the
    /// same synchronous protocol the real Keychain does.
    private final class SpyCredentials: HostCredentialWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var _pins: [HostID: SPKIHash]
        private var _removed: [HostID] = []
        private let failure: (any Error)?

        init(pins: [HostID: SPKIHash] = [:], failure: (any Error)? = nil) {
            self._pins = pins
            self.failure = failure
        }

        var removed: [HostID] {
            lock.withLock { _removed }
        }

        var pins: [HostID: SPKIHash] {
            lock.withLock { _pins }
        }

        func pin(for host: HostID) throws -> SPKIHash? {
            if let failure { throw failure }
            return lock.withLock { _pins[host] }
        }

        func removeCredentials(for host: HostID) throws {
            if let failure { throw failure }
            lock.withLock {
                _removed.append(host)
                _pins[host] = nil
            }
        }
    }

    private struct Locked: Error {}

    private static func paired(_ name: String) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: "\(name.lowercased()).local", port: 8443),
            bridgeID: "bridge-\(name.lowercased())",
            pinnedSPKI: nil,
            pairingState: .paired
        )
    }

    private static func session(host: HostID, title: String) -> Session {
        Session(
            id: UUID(),
            hostID: host,
            backendID: "claude",
            title: title,
            messages: [
                Message(id: UUID(), role: .user, text: "still here", createdAt: t0)
            ],
            createdAt: t0,
            updatedAt: t0,
            status: .idle
        )
    }

    // MARK: - The revoked host

    @Test("a revoked token moves its machine out of paired")
    func revokedTokenUnpairsTheHost() async throws {
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        let credentials = SpyCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])

        let revocation = HostRevocation(repository: repository, credentials: credentials)
        try await revocation.apply(.tokenRevoked, to: host.id)

        let stored = try #require(try await repository.host(id: host.id))
        #expect(stored.pairingState == .revoked)
        // `canConnect` is the value the UI acts on, and it is derived from two
        // fields. Asserting the state alone would pass on an implementation
        // that leaves a pin attached.
        #expect(!stored.canConnect)
    }

    @Test("the Keychain entry goes too, not just the stored state")
    func revocationClearsTheKeychain() async throws {
        // The failure this pins: writing `.revoked` to the store and stopping.
        // The store has no pin column and no token column, so a store-only
        // change looks complete in every store test while the credential stays
        // on disk — which is the residue the contract's acceptance list
        // (:686) says must be zero.
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        let credentials = SpyCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])

        let revocation = HostRevocation(repository: repository, credentials: credentials)
        try await revocation.apply(.tokenRevoked, to: host.id)

        #expect(credentials.removed == [host.id])
        #expect(credentials.pins[host.id] == nil)
    }

    // MARK: - Everything it must not touch

    @Test("only the machine that was refused is unpaired")
    func otherHostsAreUntouched() async throws {
        // bridge-protocol.md :684, verbatim: "host A 返回 401 token_revoked →
        // 只清 A 的 token，**B 的凭据与连接不受影响**".
        //
        // The natural wrong implementation is not exotic — a `removeAll()` on
        // the credential store, or a query that forgets to filter by host.
        // Both leave the user re-pairing a machine that never refused anything,
        // with no message explaining why.
        let studio = Self.paired("Studio")
        let laptop = Self.paired("Laptop")
        let repository = InMemorySessionRepository()
        try await repository.save(studio)
        try await repository.save(laptop)
        let credentials = SpyCredentials(
            pins: [studio.id: SPKIHash(base64: "AAA="), laptop.id: SPKIHash(base64: "BBB=")]
        )

        let revocation = HostRevocation(repository: repository, credentials: credentials)
        try await revocation.apply(.tokenRevoked, to: studio.id)

        let other = try #require(try await repository.host(id: laptop.id))
        #expect(other.pairingState == .paired)
        #expect(credentials.removed == [studio.id])
        #expect(credentials.pins[laptop.id] == SPKIHash(base64: "BBB="))
    }

    @Test("unpairing keeps every conversation, including the revoked machine's")
    func sessionsSurviveRevocation() async throws {
        // FR-027 / FR-036: the history is the user's, and losing a Mac's
        // credential is not a reason to lose what was said on it. The sessions
        // stay readable and become unsendable — which they already are, because
        // `canConnect` is now false.
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        try await repository.save(AgentBackend(id: "claude", displayName: "Studio Claude"), on: host.id)
        try await repository.create(Self.session(host: host.id, title: "Refactor TransportKit"))
        try await repository.create(Self.session(host: host.id, title: "Fix the flaky test"))

        let revocation = HostRevocation(
            repository: repository,
            credentials: SpyCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])
        )
        try await revocation.apply(.tokenRevoked, to: host.id)

        let sessions = try await repository.allSessions()
        #expect(Set(sessions.map(\.title)) == ["Refactor TransportKit", "Fix the flaky test"])
        // The transcript, not just the row: an implementation that kept the
        // session record and dropped its messages would pass a count check and
        // still show the user an empty conversation.
        #expect(sessions.allSatisfy { $0.messages.map(\.text) == ["still here"] })
    }

    // MARK: - Which errors qualify

    @Test("a plain rejection is not treated as a revocation")
    func unauthorizedDoesNotClearCredentials() async throws {
        // **This asserts the narrower of two readings of the contract, and the
        // contract contradicts itself here.** The prose at :118 names only
        // `token_revoked` as the code that must clear the token; the error
        // table at :587 lists `invalid_token / token_revoked` against one
        // action. `BridgeClient.error` already splits them, with a comment
        // saying one clears the Keychain entry and the other must not, and
        // `LocalisErrorTests.revokedTokenIsItsOwnCase` guards the split.
        //
        // Following the table would mean a clock skew or a flaky middlebox
        // costs the user their pairing: they did nothing wrong, the token was
        // never revoked, and they are sent back to scan a code. Following the
        // prose costs a dead token surviving until the next `token_revoked`,
        // which is what that code exists to deliver.
        //
        // Sent to TL as a contract question. If the table wins, this test
        // inverts — and it is written as a test rather than left implicit so
        // that the decision has to be made, rather than being settled by
        // whichever branch someone happened to write.
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        let credentials = SpyCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])

        let revocation = HostRevocation(repository: repository, credentials: credentials)
        try await revocation.apply(.unauthorized, to: host.id)

        let stored = try #require(try await repository.host(id: host.id))
        #expect(stored.pairingState == .paired)
        #expect(credentials.removed.isEmpty)
    }

    @Test("a changed certificate is named as such rather than as an unpairing")
    func certificateChangeIsItsOwnState() async throws {
        // Constitution V: a changed certificate has no "trust anyway" path and
        // must be *shown* to the user as what it is. Collapsing it into
        // `.revoked` would put it behind the same "Unpaired" label as a normal
        // revocation and invite a re-pair — which is precisely the action that
        // would pin whatever certificate is now being presented.
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        let credentials = SpyCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])

        let revocation = HostRevocation(repository: repository, credentials: credentials)
        try await revocation.apply(.certificatePinMismatch, to: host.id)

        let stored = try #require(try await repository.host(id: host.id))
        #expect(stored.pairingState == .certificateChanged)
        #expect(!stored.canConnect)
    }

    // MARK: - Failure

    @Test("a Keychain failure does not leave the machine looking paired")
    func keychainFailureIsNotSwallowed() async throws {
        // The dangerous half-success: the store says `.paired`, the Keychain
        // refused to delete, and the app carries on. The user sees a machine
        // that looks fine and fails every request, with a credential still on
        // disk. Either the error surfaces or the state is honest — silence is
        // the one outcome that is wrong both ways.
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        let credentials = SpyCredentials(
            pins: [host.id: SPKIHash(base64: "AAA=")],
            failure: Locked()
        )

        let revocation = HostRevocation(repository: repository, credentials: credentials)
        await #expect(throws: (any Error).self) {
            try await revocation.apply(.tokenRevoked, to: host.id)
        }
    }

    @Test("revoking a machine that is not on file is not an error")
    func unknownHostIsIgnored() async throws {
        // A 401 can arrive for a host the user removed while the request was in
        // flight. Throwing here would surface a failure about a machine that is
        // already gone, over an action the user has already got what they
        // wanted from.
        let repository = InMemorySessionRepository()
        let revocation = HostRevocation(repository: repository, credentials: SpyCredentials())

        try await revocation.apply(.tokenRevoked, to: HostID())
    }

    // MARK: - Reaching it from where a 401 actually arrives

    @Test("a 401 during a send unpairs the machine, not just the sentence on screen")
    func revocationIsReachedFromTheSendPath() async throws {
        // **Why this test is separate from the seven above.** Those all call
        // `HostRevocation` directly, so every one of them stays green on a
        // build where nothing in the app ever constructs it — which was the
        // state this type shipped in for exactly one commit, and is the same
        // shape as #29 (`isAvailable` constant-true because no caller refreshes
        // it). A type with correct behaviour and no caller is not a fix.
        //
        // The transport is rigged to refuse with `token_revoked`, which is what
        // a Mac that revoked this device answers with on every request
        // (bridge-protocol.md :118).
        let host = Self.paired("Studio")
        let repository = InMemorySessionRepository()
        try await repository.save(host)
        let backend = AgentBackend(id: "claude", displayName: "Studio Claude")
        try await repository.save(backend, on: host.id)
        let session = Self.session(host: host.id, title: "Refactor TransportKit")
        try await repository.create(session)
        let credentials = SpyCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])

        let model = await SessionDetailModel(
            repository: repository,
            sessionID: session.id,
            service: ChatService(
                transport: RefusingTransport(error: .tokenRevoked),
                repository: repository
            ),
            revocation: HostRevocation(repository: repository, credentials: credentials)
        )
        await model.load()
        await model.submit("does this go anywhere")
        await model.awaitStream()

        let stored = try #require(try await repository.host(id: host.id))
        #expect(stored.pairingState == .revoked)
        #expect(credentials.removed == [host.id])
        // The user is still told something. Unpairing silently would leave them
        // looking at a composer that stopped working for no stated reason.
        #expect(await model.loadError != nil)
        // And the conversation is still there (FR-027).
        #expect(try await repository.allSessions().count == 1)
    }

    /// A transport that refuses every turn with one error.
    ///
    /// `EchoTransport` cannot express this — it succeeds unconditionally, which
    /// is fine for the assembly tests and useless here.
    private struct RefusingTransport: AgentTransport {
        let error: LocalisError

        func send(_ request: TurnRequest) async throws -> TurnStream {
            throw error
        }

        func probe(_ backend: AgentBackend) async -> Bool { false }
    }
}
