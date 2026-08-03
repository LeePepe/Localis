import Foundation

/// Errors surfaced across Localis layers.
///
/// Every layer maps its own failures into this enum at its boundary so the UI
/// has exactly one error vocabulary to render. `userMessage` is the only text
/// intended for display — it never contains endpoints, tokens, or raw payloads.
///
/// **The bridge's own `error.message` is never carried here** (contract §6,
/// constitution I): it may contain absolute paths. Text is derived locally from
/// the code, which is also why every code in the contract's table needs a case
/// — a code with no case has nowhere to get its wording from but the wire.
///
/// `Codable` because `SessionStatus.error` is persisted with the session: a
/// conversation that ended in a failure should still read as failed after a
/// relaunch, rather than silently coming back as idle.
public enum LocalisError: Error, Codable, Hashable, Sendable {
    /// The agent endpoint was unreachable (offline, wrong host, refused).
    case unreachable
    /// The connection dropped mid-stream.
    case connectionLost
    /// The backend answered, but not in a shape we understand.
    case malformedResponse
    /// The backend rejected our credentials (401 `invalid_token`).
    case unauthorized
    /// User input failed validation before any request was made.
    case invalidInput(field: String)
    /// The operation was cancelled by the user.
    case cancelled

    // MARK: - Contract §6

    /// 401 `token_revoked` — the host revoked this device's pairing.
    ///
    /// Separate from `unauthorized` because the required action differs: this
    /// one means clear the stored token and re-pair. Collapsing the two would
    /// either discard a good token or leave a dead one on the device.
    case tokenRevoked
    /// 404 `unknown_model` — the backend is no longer advertised by this host.
    case unknownBackend
    /// 409 `session_busy` — the previous turn has not finished.
    case sessionBusy
    /// 503 `backend_unavailable`, with the host's short reason code when it
    /// sent one (`not_logged_in`, …).
    ///
    /// The reason is an **open** value set (constitution IV) and is a machine
    /// code, never the bridge's free text. Unrecognised codes fall back to
    /// generic wording rather than being shown raw.
    case backendUnavailable(reason: String?)
    /// 426 `protocol_upgrade_required`, naming which side is behind.
    case protocolUpgradeRequired(side: UpgradeSide)
    /// 410 `turn_expired` — past the host's retention window (Amendment C).
    case turnExpired
    /// 404 `unknown_turn` — resuming or cancelling a turn the host has no
    /// record of (Amendment C).
    case unknownTurn
    /// 403 `turn_not_yours` — the resuming device is not the one that started
    /// the turn. Nothing about that turn may be revealed.
    case turnNotYours
    /// The presented certificate does not match the pinned one.
    ///
    /// Terminal by design: constitution V allows no "trust anyway" path, and no
    /// retry either — retrying cannot make a certificate match.
    case certificatePinMismatch
    /// The host's buffer limit truncated the output (contract §3.3).
    ///
    /// The message must be marked `interrupted`, never `complete`: better to
    /// say content was lost than to present a partial answer as whole.
    case truncated

    /// Which end of the connection needs updating.
    ///
    /// A conclusion, not two version numbers to re-compare at each call site —
    /// sending the user to update the wrong end is worse than saying nothing.
    public enum UpgradeSide: String, Codable, Hashable, Sendable {
        /// The host speaks a newer protocol than this build.
        case app
        /// The host speaks an older protocol than this build requires.
        case bridge
    }

    /// Whether offering the user a retry makes sense.
    ///
    /// Note what is absent: a certificate mismatch and a turn belonging to
    /// another device are not retryable, because repeating the request cannot
    /// change either outcome.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .connectionLost, .malformedResponse,
             .sessionBusy, .backendUnavailable,
             .turnExpired, .unknownTurn, .truncated:
            return true
        case .unauthorized, .invalidInput, .cancelled, .tokenRevoked,
             .unknownBackend, .protocolUpgradeRequired,
             .turnNotYours, .certificatePinMismatch:
            return false
        }
    }

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
        case .tokenRevoked:
            return "This Mac no longer recognises this device. Pair again to continue."
        case .unknownBackend:
            return "That agent is no longer available on this Mac."
        case .sessionBusy:
            return "The previous message is still being answered."
        case .backendUnavailable(let reason):
            return Self.unavailableMessage(for: reason)
        case .protocolUpgradeRequired(let side):
            switch side {
            case .app:
                return "This Mac is running a newer Bridge. Update Localis to continue."
            case .bridge:
                return "This Mac is running an older Bridge. Update it to continue."
            }
        case .turnExpired:
            return "That reply is no longer available on the Mac. Send it again."
        case .unknownTurn:
            return "The Mac has no record of that reply. Send it again."
        case .turnNotYours:
            return "That reply belongs to a different device."
        case .certificatePinMismatch:
            return "This Mac's identity has changed. Pair again to confirm it's the same machine."
        case .truncated:
            return "The reply was too long to keep in full, so part of it was lost."
        }
    }

    /// Maps an open reason code to wording, falling back to generic text.
    ///
    /// The raw code is deliberately not interpolated into the fallback: it is a
    /// wire token, not a phrase, and showing it reads as a leak to the user.
    private static func unavailableMessage(for reason: String?) -> String {
        switch reason {
        case "not_logged_in":
            return "That agent isn't signed in on the Mac."
        case "rate_limited":
            return "That agent has hit its rate limit. Try again shortly."
        default:
            return "That agent isn't available right now."
        }
    }
}
