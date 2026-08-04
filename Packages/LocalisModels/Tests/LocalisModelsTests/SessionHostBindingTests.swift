import Foundation
import Testing

@testable import LocalisModels

/// FR-030: a session belongs to exactly one host, for life. The backend may
/// change, but only for the next message.
@Suite("Session host binding")
struct SessionHostBindingTests {
    private static let host = HostID()
    private static let other = HostID()
    private static let created = Date(timeIntervalSince1970: 1_700_000_000)
    private static let later = Date(timeIntervalSince1970: 1_700_000_060)

    private static func makeSession(messages: [Message] = []) -> Session {
        Session(
            id: UUID(),
            hostID: host,
            backendID: "claude",
            title: "Test",
            messages: messages,
            createdAt: created,
            updatedAt: created
        )
    }

    @Test("no operation can move a session to another host")
    func hostIDIsImmutableAcrossEveryTransform() {
        // FR-030: resume semantics, workspace paths, the backend list and the
        // skill catalogue are all host-local, so "move this chat to the other
        // Mac" is not a coherent operation. There is deliberately no API for it.
        let session = Self.makeSession()

        let transformed = session
            .withTitle("Renamed", at: Self.later)
            .withBackendID("codex", at: Self.later)
            .withStatus(.streaming)
            .appending(Message(id: UUID(), role: .user, text: "hi", createdAt: Self.later), at: Self.later)

        #expect(transformed.hostID == Self.host)
        #expect(transformed.hostID != Self.other)
    }

    @Test("the backend can be switched and takes effect from the next message")
    func backendIsSwitchableForFutureMessages() {
        // Amendment A §3 (unchanged behaviour): switching the backend applies to
        // the next message; history keeps whatever produced it.
        let session = Self.makeSession(messages: [
            Message(id: UUID(), role: .assistant, text: "from claude", createdAt: Self.created)
        ])

        let switched = session.withBackendID("codex", at: Self.later)

        #expect(switched.backendID == "codex")
        #expect(session.backendID == "claude")
        #expect(switched.messages == session.messages)
        #expect(switched.updatedAt == Self.later)
    }

    @Test("the session exposes its backend as a host-qualified ref")
    func backendRefIsHostQualified() {
        // FR-040: any lookup by backend must carry the host, or two machines
        // that both expose "claude" will shadow each other.
        let session = Self.makeSession()

        #expect(session.backendRef == BackendRef(hostID: Self.host, backendID: "claude"))
    }

    @Test("a new session starts idle")
    func defaultStatusIsIdle() {
        #expect(Self.makeSession().status == .idle)
    }

    @Test("orphaning a session makes it read-only without deleting anything")
    func orphaningPreservesTheTranscript() {
        // FR-027 / SC-012: unpairing a host must not delete a single message.
        // The session goes read-only and the user decides about deletion.
        let message = Message(id: UUID(), role: .user, text: "keep me", createdAt: Self.created)
        let session = Self.makeSession(messages: [message])

        let orphaned = session.orphaned()

        #expect(orphaned.status == .orphaned)
        #expect(orphaned.messages == [message])
        #expect(!orphaned.canSend)
        #expect(orphaned.hostID == Self.host)
        // The row does not move (#28). `updatedAt` is the session list's sort
        // key and nothing renders it, so bumping it here would announce every
        // conversation on an unpaired Mac as freshly active — at the exact
        // moment they all became unsendable. Asserted in the model rather than
        // only where it is called: this is a property of the transition, and
        // `orphaned()` has no production caller yet to catch it downstream.
        #expect(orphaned.updatedAt == session.updatedAt)
    }

    @Test("an orphaned session can be reactivated when its host returns")
    func reactivationRestoresSending() {
        // spec §Edge Cases: re-pairing a machine whose bridge id / SPKI matches
        // brings its orphaned sessions back.
        let session = Self.makeSession()
        let orphaned = session.orphaned()

        let revived = orphaned.reactivated()

        #expect(revived.status == .idle)
        #expect(revived.canSend)
        // Re-pairing is not activity either: a Mac coming back does not mean
        // any of its conversations received anything.
        #expect(revived.updatedAt == session.updatedAt)
    }

    @Test("sending is only allowed from idle")
    func canSendOnlyWhenIdle() {
        // FR-036 / FR-053: an unreachable or busy session must visibly refuse
        // input rather than silently accept text that cannot be delivered.
        let session = Self.makeSession()

        #expect(session.withStatus(.idle).canSend)
        #expect(!session.withStatus(.disconnected).canSend)
        #expect(!session.withStatus(.connecting).canSend)
        #expect(!session.withStatus(.streaming).canSend)
        #expect(!session.withStatus(.error(.unreachable)).canSend)
        #expect(!session.withStatus(.orphaned).canSend)
    }

    @Test("no status change counts as activity")
    func statusChangesNeverMoveTheRow() {
        // The general form of the two assertions above, over every status.
        //
        // **Why this is worth its own test when `withStatus` no longer takes a
        // timestamp to pass.** The signature is the guard, and a signature is
        // exactly the kind of thing a later change reverts for a local reason —
        // one caller that genuinely wants both, and `at:` comes back with a
        // default. This fails the moment it does, and names the cost: the list
        // silently re-sorts by "recently touched" while claiming to be sorted
        // by activity (#28). Nothing errors, so nothing else would notice.
        let session = Self.makeSession()

        for status: SessionStatus in [
            .disconnected, .connecting, .idle, .streaming, .error(.unreachable), .orphaned
        ] {
            #expect(session.withStatus(status).updatedAt == session.updatedAt)
        }
    }

    @Test("history stays readable in every non-idle state")
    func historyIsAlwaysReadable() {
        // FR-036: a host being off does not hide its transcripts. Only sending
        // is disabled.
        let message = Message(id: UUID(), role: .assistant, text: "old answer", createdAt: Self.created)
        let session = Self.makeSession(messages: [message])

        for status: SessionStatus in [.disconnected, .connecting, .idle, .streaming, .error(.unreachable), .orphaned] {
            #expect(session.withStatus(status).messages == [message])
        }
    }

    @Test("round-trips through Codable including the host binding")
    func codableRoundTrip() throws {
        let session = Self.makeSession(messages: [
            Message(id: UUID(), role: .user, text: "hi", createdAt: Self.created)
        ])

        let decoded = try JSONDecoder().decode(
            Session.self,
            from: try JSONEncoder().encode(session)
        )

        #expect(decoded == session)
        #expect(decoded.hostID == Self.host)
    }
}

@Suite("SessionStatus")
struct SessionStatusTests {
    @Test("error carries the user-facing failure")
    func errorCarriesItsCause() {
        let status = SessionStatus.error(.unreachable)

        #expect(status == .error(.unreachable))
        #expect(status != .error(.unauthorized))
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        for status: SessionStatus in [.disconnected, .connecting, .idle, .streaming, .orphaned, .error(.connectionLost)] {
            let decoded = try JSONDecoder().decode(
                SessionStatus.self,
                from: try JSONEncoder().encode(status)
            )
            #expect(decoded == status)
        }
    }
}
