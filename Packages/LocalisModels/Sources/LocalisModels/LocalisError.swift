import Foundation

/// Errors surfaced across Localis layers.
///
/// Every layer maps its own failures into this enum at its boundary so the UI
/// has exactly one error vocabulary to render. `userMessage` is the only text
/// intended for display — it never contains endpoints, tokens, or raw payloads.
public enum LocalisError: Error, Equatable, Sendable {
    /// The agent endpoint was unreachable (offline, wrong host, refused).
    case unreachable
    /// The connection dropped mid-stream.
    case connectionLost
    /// The backend answered, but not in a shape we understand.
    case malformedResponse
    /// The backend rejected our credentials.
    case unauthorized
    /// User input failed validation before any request was made.
    case invalidInput(field: String)
    /// The operation was cancelled by the user.
    case cancelled

    /// Short, user-facing description. Callers localize at the UI boundary.
    public var userMessage: String {
        switch self {
        case .unreachable:
            return "Can't reach that agent. Check it's running and on the same network."
        case .connectionLost:
            return "The connection dropped. Tap to retry."
        case .malformedResponse:
            return "The agent sent a response Localis couldn't read."
        case .unauthorized:
            return "The agent rejected these credentials."
        case .invalidInput(let field):
            return "Please check the \(field) field."
        case .cancelled:
            return "Cancelled."
        }
    }
}
