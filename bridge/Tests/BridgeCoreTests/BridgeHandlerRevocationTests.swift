import Foundation
import Testing

@testable import BridgeCore

/// The revoked token's journey through the handler, which is where the code the
/// phone acts on is actually chosen.
///
/// Separate from `TokenStoreRevocationTests` on purpose: that suite proves the
/// store can tell the two cases apart, and this one proves the handler *says* so
/// on the wire. Both halves have failed independently in this codebase — a
/// correct store behind a handler that flattened the answer would look entirely
/// green while the phone kept a dead credential.
@Suite("Handler — revoked tokens")
struct BridgeHandlerRevocationTests {
    private static let grant = TokenStore.Grant(deviceName: "Test Phone", deviceID: "dev-1")

    private static func failure(_ response: BridgeResponse) throws -> (status: Int, code: String) {
        guard case let .complete(status, _, body) = response else {
            Issue.record("expected a complete response, got a stream")
            throw CancellationError()
        }
        let object = try JSONSerialization.jsonObject(with: Data(body))
        let frame = try #require(object as? [String: Any])
        let error = try #require(frame["error"] as? [String: Any])
        return (status, try #require(error["code"] as? String))
    }

    private static func handler(tokens: TokenStore) -> BridgeHandler {
        BridgeHandler(
            catalog: BackendCatalog(backends: []),
            runners: [],
            tokens: tokens,
            coordinator: TurnCoordinator(sessions: SessionStore()),
            bridgeName: "test",
            bridgeID: "test-id"
        )
    }

    private static func request(token: String) -> BridgeRequest {
        BridgeRequest(
            method: "GET",
            uri: "/v1/models",
            headers: ["Authorization": "Bearer \(token)"],
            body: []
        )
    }

    /// **The red-green pair at the handler level.**
    ///
    /// The 200 first. Asserting only the 401 would not distinguish "revocation
    /// worked" from "this token never worked" — and the second is exactly what a
    /// broken test setup produces.
    @Test("the same token answers 200, then 401 token_revoked after a revoke")
    func revokedTokenGetsRevokedCode() async throws {
        let tokens = TokenStore()
        await tokens.issue(token: "tok-abc", to: Self.grant)
        let handler = Self.handler(tokens: tokens)

        let before = await handler.respond(to: Self.request(token: "tok-abc"))
        #expect(before.status == 200, "the token did not work before revocation — the assertion below would prove nothing")

        await tokens.revoke(deviceID: Self.grant.deviceID)

        let after = await handler.respond(to: Self.request(token: "tok-abc"))
        let (status, code) = try Self.failure(after)
        #expect(status == 401)
        #expect(code == "token_revoked")
    }

    /// **The other half, and the one the client cannot check.** A token nobody
    /// revoked keeps `invalid_token`. If this widened, the phone would erase a
    /// working pairing whenever a header was mangled — and since both codes are
    /// a 401 with the same shape, nothing on the client side could tell.
    @Test("an unknown token still gets invalid_token, not token_revoked")
    func unknownTokenKeepsInvalidCode() async throws {
        let tokens = TokenStore()
        await tokens.issue(token: "tok-abc", to: Self.grant)
        await tokens.revoke(deviceID: Self.grant.deviceID)

        let response = await Self.handler(tokens: tokens).respond(to: Self.request(token: "tok-never-issued"))
        let (status, code) = try Self.failure(response)
        #expect(status == 401)
        #expect(code == "invalid_token", "an unrecognised token was reported as revoked; the phone would erase a pairing over it")
    }

    /// A request with no `Authorization` header at all is not a revocation
    /// either — there is no token to have revoked.
    @Test("a missing token gets invalid_token")
    func missingTokenKeepsInvalidCode() async throws {
        let tokens = TokenStore()
        await tokens.issue(token: "tok-abc", to: Self.grant)
        await tokens.revoke(deviceID: Self.grant.deviceID)

        let response = await Self.handler(tokens: tokens).respond(
            to: BridgeRequest(method: "GET", uri: "/v1/models", headers: [:], body: [])
        )
        let (_, code) = try Self.failure(response)
        #expect(code == "invalid_token")
    }

    /// Pairing stays reachable after a revoke — it is the route with no
    /// authentication, and it is the user's way back. A revoked device that
    /// could not re-pair would be permanently locked out by the act meant to be
    /// undoable.
    @Test("pairing is still reachable with a revoked token in the header")
    func pairingRemainsReachable() async throws {
        let tokens = TokenStore()
        await tokens.issue(token: "tok-abc", to: Self.grant)
        await tokens.revoke(deviceID: Self.grant.deviceID)

        let response = await Self.handler(tokens: tokens).respond(
            to: BridgeRequest(
                method: "POST",
                uri: "/localis/v1/pair",
                headers: ["Authorization": "Bearer tok-abc"],
                body: [UInt8](Data("{\"code\":\"000000\"}".utf8))
            )
        )

        // Not 200 — no pairing window is open here. The point is that it is not
        // a 401 about the token: the request reached the pairing handler.
        let (_, code) = try Self.failure(response)
        #expect(code != "token_revoked" && code != "invalid_token", "a revoked device cannot re-pair")
    }
}
