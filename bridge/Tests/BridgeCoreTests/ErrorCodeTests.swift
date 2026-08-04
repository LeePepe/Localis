import Foundation
import Testing

@testable import BridgeCore

/// The error codes on the wire must be ones the client knows (contract §6).
///
/// This suite exists because of a code that was *reasonable* rather than
/// *specified*. The client maps an unrecognised code to `malformedResponse`,
/// whose message is about a broken bridge — so an off-vocabulary code does not
/// fail loudly here, it surfaces on the phone as the wrong explanation for a
/// situation the bridge understood perfectly well.
@Suite("Wire error codes")
struct ErrorCodeTests {
    /// The 401 codes the contract's error table lists, and the only ones the
    /// iOS side maps to "clear the token and re-pair".
    private static let authenticationCodes: Set<String> = ["invalid_token", "token_revoked"]

    /// The status and error code of a complete response.
    ///
    /// A `.stream` here is itself a failure: an auth rejection that opened an
    /// SSE stream would never reach the client's error path at all.
    private static func failure(_ response: BridgeResponse) throws -> (status: Int, code: String) {
        guard case let .complete(status, _, body) = response else {
            Issue.record("expected a complete response, got a stream")
            throw CancellationError()
        }
        let object = try JSONSerialization.jsonObject(with: Data(body))
        let frame = try #require(object as? [String: Any])
        let error = try #require(frame["error"] as? [String: Any])
        let code = try #require(error["code"] as? String)
        return (status, code)
    }

    private static func handler() -> BridgeHandler {
        BridgeHandler(
            catalog: BackendCatalog(backends: []),
            runners: [],
            tokens: TokenStore(),
            coordinator: TurnCoordinator(sessions: SessionStore()),
            bridgeName: "test",
            bridgeID: "test-id"
        )
    }

    /// A request with no credentials at all.
    @Test("a missing token is answered with a code the client knows")
    func missingToken() async throws {
        let response = await Self.handler().respond(
            to: BridgeRequest(method: "GET", uri: "/v1/models", headers: [:], body: [])
        )

        let (status, code) = try Self.failure(response)
        #expect(status == 401)
        #expect(
            Self.authenticationCodes.contains(code),
            "'\(code)' is not in the contract's 401 vocabulary — the client maps it to malformedResponse"
        )
    }

    /// A token that is well-formed but was never issued by this bridge.
    ///
    /// This used to be described as "the shape a client holds after a restart",
    /// which stopped being true when grants were persisted (2026-08-04). It is
    /// now reachable the ways a grant actually ends: the user unpaired
    /// (FR-027), the grant file was deleted, or the token was never real.
    @Test("an unknown token is answered with a code the client knows")
    func unknownToken() async throws {
        let response = await Self.handler().respond(
            to: BridgeRequest(
                method: "GET",
                uri: "/v1/models",
                headers: ["authorization": "Bearer not-a-token-this-bridge-issued"],
                body: []
            )
        )

        let (status, code) = try Self.failure(response)
        #expect(status == 401)
        #expect(
            Self.authenticationCodes.contains(code),
            "'\(code)' is not in the contract's 401 vocabulary — the client maps it to malformedResponse"
        )
    }

    /// Chat is checked separately from `/v1/models`: the auth gate is shared,
    /// but a future refactor could easily make it not be, and this is the route
    /// a user actually hits.
    @Test("chat answers an unknown token with a code the client knows")
    func unknownTokenOnChat() async throws {
        let response = await Self.handler().respond(
            to: BridgeRequest(
                method: "POST",
                uri: "/v1/chat/completions",
                headers: ["authorization": "Bearer not-a-token-this-bridge-issued"],
                body: [UInt8](#"{"model":"claude","messages":[]}"#.utf8)
            )
        )

        let (status, code) = try Self.failure(response)
        #expect(status == 401)
        #expect(Self.authenticationCodes.contains(code), "chat returned '\(code)'")
    }
}
