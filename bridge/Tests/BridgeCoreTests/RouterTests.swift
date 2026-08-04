import Foundation
import Testing

@testable import BridgeCore

/// Which handler a request reaches.
///
/// Routing is where an authentication mistake becomes a security hole rather
/// than a bug, so these tests care as much about what a path *does not* reach
/// as about what it does.
@Suite("Router — path and method dispatch")
struct RouterTests {
    /// The contract puts pairing under `/localis/v1/` and everything else under
    /// `/v1/` (§1 vs §2). The iOS client hard-codes both, so a "tidier" unified
    /// prefix would be a silent 404 at the one moment the user cannot proceed
    /// without it.
    @Test("the contract's two prefixes both resolve", arguments: [
        ("POST", "/localis/v1/pair", Route.pair),
        ("GET", "/v1/models", .models),
        ("GET", "/v1/skills", .skills),
        ("POST", "/v1/chat/completions", .chatCompletions),
    ])
    func contractPaths(method: String, path: String, expected: Route) {
        #expect(Router.route(method: method, uri: path) == expected)
    }

    /// `GET /v1/skills` was found by reading `BridgeClient.skills()`, not the
    /// contract prose — the client calls it, so it exists whatever the spec
    /// happens to enumerate. A 404 here does not read as "unimplemented" on the
    /// iOS side; `SkillCatalog.decode` gets a body it cannot parse.
    @Test("the skills catalogue the iOS client calls is routed")
    func skillsRouted() {
        #expect(Router.route(method: "GET", uri: "/v1/skills") == .skills)
        #expect(Router.route(method: "POST", uri: "/v1/skills") == .methodNotAllowed)
    }

    /// Turn ids appear inside the path, so these routes only work if the router
    /// extracts rather than matches literally.
    @Test("turn routes carry the id", arguments: [
        ("/v1/turns/t-abc/cancel", Route.cancelTurn(id: "t-abc")),
        ("/v1/turns/t-abc/resume", Route.resumeTurn(id: "t-abc")),
    ])
    func turnRoutes(path: String, expected: Route) {
        #expect(Router.route(method: "POST", uri: path) == expected)
    }

    /// A query string is not part of the path. Matching on the raw URI would
    /// make `/v1/models?refresh=1` a 404 — and query strings arrive from
    /// clients we do not control.
    @Test("a query string does not change the route")
    func queryStringIgnored() {
        #expect(Router.route(method: "GET", uri: "/v1/models?refresh=1") == .models)
    }

    /// Wrong method on a real path is 405, not 404: the distinction is what
    /// tells a client "you called this wrong" rather than "this does not
    /// exist".
    @Test("a known path with the wrong method is a method mismatch")
    func methodMismatch() {
        #expect(Router.route(method: "GET", uri: "/v1/chat/completions") == .methodNotAllowed)
    }

    @Test("an unknown path is not found")
    func unknownPath() {
        #expect(Router.route(method: "GET", uri: "/v1/nonsense") == .notFound)
    }

    /// **Pairing is the only route reachable without a token** — it is what
    /// produces the token (§1). Any *other* route becoming unauthenticated is a
    /// hole, so this asserts the whole set rather than one member of it.
    @Test("only pairing is exempt from authentication", arguments: [
        Route.pair,
        .models,
        .skills,
        .chatCompletions,
        .cancelTurn(id: "t"),
        .resumeTurn(id: "t"),
        .notFound,
        .methodNotAllowed,
    ])
    func onlyPairingIsUnauthenticated(route: Route) {
        #expect(route.requiresAuthentication == (route != .pair))
    }

    /// Path traversal must not reach a handler. A router that normalised `..`
    /// away would resolve this to a real route.
    @Test("traversal segments do not resolve")
    func traversalDoesNotResolve() {
        #expect(Router.route(method: "GET", uri: "/v1/../v1/models") == .notFound)
    }

    /// An empty turn id must not produce a route with an empty identifier,
    /// which would go looking for a turn that cannot exist.
    @Test("an empty turn id does not route")
    func emptyTurnID() {
        #expect(Router.route(method: "POST", uri: "/v1/turns//cancel") == .notFound)
    }
}
