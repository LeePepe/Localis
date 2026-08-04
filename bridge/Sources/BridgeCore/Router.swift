import Foundation

/// Which handler a request reaches.
///
/// A closed enum rather than a table of closures: routing decides what is
/// reachable without a token, and an enum makes that decision something the
/// compiler can see exhaustively rather than something spread across
/// registration calls.
public enum Route: Sendable, Hashable {
    /// `POST /localis/v1/pair` (§1). The one route that issues credentials
    /// rather than requiring them.
    case pair
    /// `GET /v1/models` (§2).
    case models
    /// `POST /v1/chat/completions` (§3).
    case chatCompletions
    /// `POST /v1/turns/{id}/cancel` (§4).
    case cancelTurn(id: String)
    /// `POST /v1/turns/{id}/resume` (§3.3).
    case resumeTurn(id: String)
    /// The path exists but not for this method — 405, which tells a client it
    /// called correctly-named endpoint the wrong way.
    case methodNotAllowed
    /// No such path — 404.
    case notFound

    /// Whether a bearer token is required.
    ///
    /// Expressed as "everything except pairing" rather than as a list of
    /// protected routes: a new route added to this enum is protected by
    /// default, and forgetting to add it to a list is the exact mistake that
    /// leaves an endpoint open.
    public var requiresAuthentication: Bool {
        self != .pair
    }
}

/// Maps a method and URI onto a route.
///
/// Deliberately literal — no parameter patterns, no normalisation, no
/// registration. The contract has six endpoints, and a table-driven router
/// would add a layer of indirection whose main effect is to make it harder to
/// see what is reachable unauthenticated.
public enum Router {
    /// Resolves one request line.
    ///
    /// Never throws and never returns nil: an unroutable request is a route
    /// (`.notFound`), so the caller has one uniform path to a response and
    /// cannot forget the failure case.
    public static func route(method: String, uri: String) -> Route {
        let segments = pathSegments(of: uri)

        // Turn routes first: they are the only ones with a variable segment, so
        // matching them by shape keeps the literal cases below exhaustive and
        // readable.
        if segments.count == 4, segments[0] == "v1", segments[1] == "turns" {
            let id = segments[2]
            switch segments[3] {
            case "cancel":
                return method == "POST" ? .cancelTurn(id: id) : .methodNotAllowed
            case "resume":
                return method == "POST" ? .resumeTurn(id: id) : .methodNotAllowed
            default:
                return .notFound
            }
        }

        switch segments {
        case ["localis", "v1", "pair"]:
            return method == "POST" ? .pair : .methodNotAllowed

        case ["v1", "models"]:
            return method == "GET" ? .models : .methodNotAllowed

        case ["v1", "chat", "completions"]:
            return method == "POST" ? .chatCompletions : .methodNotAllowed

        default:
            return .notFound
        }
    }

    /// Splits a URI's path into non-empty segments.
    ///
    /// Two properties matter more than the splitting:
    ///
    /// **The query string is dropped.** Matching the raw URI would turn
    /// `/v1/models?refresh=1` into a 404, and query strings arrive from clients
    /// we do not control.
    ///
    /// **`..` is not resolved.** Traversal segments are kept as literal
    /// segments, so they match nothing and fall through to `.notFound`. A
    /// router that normalised them would let `/v1/../v1/models` resolve —
    /// harmless here, but the same normalisation is how a path check gets
    /// bypassed once paths reach a filesystem.
    private static func pathSegments(of uri: String) -> [String] {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri

        // Dropping empty segments makes `/v1/turns//cancel` fall through rather
        // than route with an empty id — a turn that cannot exist, looked up
        // anyway.
        return path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }
}
