import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// `probe` answers *why*, not just *whether* (#40).
///
/// The `Bool` it used to return was the second of the two layers named in
/// `HostUnreachableReason.userMessage`'s note: a socket error reached
/// `BridgeClient.perform`'s catch-all, which collapsed every `URLError` into
/// `.unreachable` (#34), and whatever survived that hit a return type with no
/// room for a reason at all. A screen could then say only "unavailable" for four
/// situations that call for four different user actions.
@Suite("probe carries the reason")
struct ProbeReachabilityTests {
    // MARK: - The mapping

    /// The four reasons must each be reachable from an error the wire can
    /// actually produce. A mapping whose cases are all funnelled from one error
    /// would satisfy exhaustiveness and still tell the user nothing.
    @Test("each unreachable reason is produced by a distinct transport error")
    func everyReasonHasADistinctSource() {
        let produced: [LocalisError: HostUnreachableReason] = [
            .unreachable(): .offline,
            .certificatePinMismatch: .certificateRejected,
            .unauthorized: .unauthorized,
            .protocolUpgradeRequired(side: .app): .unsupportedProtocol,
        ]

        for (error, expected) in produced {
            #expect(HostReachability(failure: error) == .unreachable(reason: expected))
        }

        // Four distinct sources for four cases: the point of the type.
        #expect(Set(produced.values).count == HostUnreachableReason.allCases.count)
    }

    /// Both 401 codes land on `.unauthorized`, and this is a ruling rather than
    /// an oversight (`HostRevocation`, 2026-08-04). `token_revoked` and
    /// `invalid_token` demand opposite *credential* actions, which is why
    /// `LocalisError` keeps them apart — but the question this enum answers is
    /// "why is this host unusable", and there both answers are "pair again".
    /// The action difference travels via `HostPairingState.revoked` instead.
    ///
    /// Written as an assertion because the natural-looking fix — a fifth reason
    /// — would turn `HostUnreachableReasonWordingTests.reasonsAreNotInterchangeable`
    /// red, and someone hitting that test should find the reason here.
    @Test("both 401 codes give the same reason, deliberately")
    func revokedAndUnauthorizedShareAReason() {
        #expect(HostReachability(failure: .tokenRevoked) == .unreachable(reason: .unauthorized))
        #expect(HostReachability(failure: .unauthorized) == .unreachable(reason: .unauthorized))
    }

    /// An error with no specific reason must not invent one. `.offline` is the
    /// honest fallback: it is the only case whose user action ("check it's awake
    /// and on the network") is harmless when the real cause was something else.
    /// Defaulting to `certificateRejected` would tell a user to re-pair a
    /// machine whose certificate is fine.
    @Test("an unmapped failure falls back to offline rather than guessing")
    func unmappedFailureIsOffline() {
        #expect(HostReachability(failure: .malformedResponse) == .unreachable(reason: .offline))
        #expect(HostReachability(failure: .sessionBusy) == .unreachable(reason: .offline))
    }

    // MARK: - What probe returns

    @Test("a listed, available backend reads as reachable")
    func availableBackendIsReachable() async {
        let transport = StubTransport(result: .reachable)

        #expect(await transport.probe(Self.backend) == .reachable)
    }

    /// The distinction the `Bool` could not express: a host that answered and
    /// said "no" is not the same as a host that did not answer.
    @Test("a certificate rejection is not reported as offline")
    func certificateRejectionKeepsItsReason() async {
        let transport = StubTransport(result: .unreachable(reason: .certificateRejected))

        #expect(await transport.probe(Self.backend) == .unreachable(reason: .certificateRejected))
        #expect(await transport.probe(Self.backend) != .unreachable(reason: .offline))
    }

    /// `.unknown` is not a failure. Before the first probe answers, claiming a
    /// host is unreachable is a lie the user has to disprove — the same reason
    /// `HostReachability` has the case at all.
    @Test("unknown is distinct from unreachable")
    func unknownIsNotUnreachable() async {
        let transport = StubTransport(result: .unknown)

        let result = await transport.probe(Self.backend)
        #expect(result == .unknown)
        if case .unreachable = result {
            Issue.record("an unanswered probe must not read as an established failure")
        }
    }

    // MARK: - What must not change

    /// **`probe` must not become throwing.** It runs while the host list is
    /// being drawn; an unreachable Mac turning into an error the user must
    /// dismiss before seeing the list is the behaviour the `try?` in
    /// `BridgeClient.probe` exists to prevent. Carrying a reason was never a
    /// reason to start propagating.
    ///
    /// Enforced by the signature: this compiles only while `probe` is
    /// non-throwing, and stops compiling the moment someone removes the `try?`
    /// and lets `models()` escape.
    @Test("probe stays non-throwing so the host list always draws")
    func probeDoesNotThrow() async {
        let transport: any AgentTransport = StubTransport(result: .unreachable(reason: .offline))

        // No `try`, and no `await ... catch`: a throwing `probe` fails to build.
        let reachability = await transport.probe(Self.backend)

        #expect(reachability == .unreachable(reason: .offline))
    }

    private static let backend = AgentBackend(id: "alpha", displayName: "Alpha")
}

/// Returns a fixed reachability, so a test says which situation it is about
/// without standing up a socket.
private struct StubTransport: AgentTransport {
    let result: HostReachability

    func send(_ request: TurnRequest) async throws -> TurnStream {
        throw LocalisError.unreachable()
    }

    func probe(_ backend: AgentBackend) async -> HostReachability { result }

    /// Mirrors `result`: this suite is about `probe`, and a description that
    /// disagreed with it would be a second answer no test here reads.
    func refresh(_ backend: AgentBackend) async -> BackendDescription {
        result == .reachable ? .listed(backend) : .unknown
    }
}
