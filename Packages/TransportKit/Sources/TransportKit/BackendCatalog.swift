import Foundation
import LocalisModels

/// The parsed result of `GET /v1/models` for **one** host (contract §2).
///
/// There is no notion of "all hosts" here, by design: a `BridgeClient` is
/// instantiated per host, so a catalogue always belongs to exactly one machine.
/// Two machines each advertising `claude` advertise two different backends, and
/// keeping them apart is the caller's job via `BackendRef` (Amendment A §1.1).
public struct BackendCatalog: Sendable {
    /// What this machine can do — resume, retention, telemetry (§2.1).
    public let host: HostCapabilities
    /// The backends it exposes, in the order the bridge listed them.
    public let backends: [BackendListing]

    /// Parses a `/v1/models` body.
    ///
    /// - Throws: `LocalisError.malformedResponse` when the body is not JSON or
    ///   has no `data` array. Individual malformed entries are skipped instead:
    ///   one bad backend must not cost the user the other five.
    public init(data: Data) throws {
        guard let json = JSONValue(jsonData: data), let entries = json["data"]?.arrayValue else {
            throw LocalisError.malformedResponse
        }

        host = HostCapabilities(json: json["x_localis"])
        backends = entries.compactMap(BackendListing.init(json:))
    }
}

/// One backend plus whether it can be used right now.
///
/// Availability is separate from `AgentBackend` because it is an observation
/// about this moment — an agent that is not logged in becomes available the
/// second the user logs in — while the backend itself is a capability
/// descriptor.
public struct BackendListing: Sendable, Hashable {
    public let backend: AgentBackend
    public let availability: Availability

    /// Whether the backend can take a request right now.
    ///
    /// The reason is carried so the UI can say something the user can act on
    /// ("not logged in") instead of a bare "unavailable". It is a bridge-supplied
    /// code, mapped to text locally — never a `switch` on which backend it is.
    public enum Availability: Sendable, Hashable {
        case available
        case unavailable(reason: String?)
    }

    init?(json: JSONValue) {
        // The wire id is the identity. Without it there is nothing to send a
        // request to, so the entry is skipped rather than half-built.
        guard let id = json["id"]?.stringValue, !id.trimmed.isEmpty else { return nil }

        let extensions = json["x_localis"]

        backend = AgentBackend(
            id: id,
            // Falling back to the id keeps a nameless backend selectable. A
            // blank row would be indistinguishable from a rendering bug.
            displayName: extensions?["display_name"]?.stringValue ?? id,
            // Unknown values are kept, not filtered: the client tests for
            // capabilities it knows, so an unrecognised one is inert — and
            // dropping it would erase a flag the moment a bridge ships one
            // (constitution IV).
            capabilities: Set(extensions?["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        )

        // Absent means available: an older bridge does not send the field, and
        // treating silence as "unavailable" would hide working backends.
        if extensions?["available"]?.boolValue == false {
            availability = .unavailable(reason: extensions?["unavailable_reason"]?.stringValue)
        } else {
            availability = .available
        }
    }
}

/// What one host declares about itself (contract §2.1, Amendment C).
///
/// Every field is optional on the wire and every default here is the safe one.
/// These are per host, always: one machine supporting resumable turns says
/// nothing about another, and inferring across them is exactly the silent
/// cross-talk Amendment A exists to prevent.
public struct HostCapabilities: Sendable, Hashable {
    /// Whether a dropped connection leaves the turn running (§3.2).
    ///
    /// **Defaults to false, and that default is load-bearing.** An older bridge
    /// does not know the field; assuming the work survives would leave the app
    /// waiting to resume a turn that was cancelled the moment the socket
    /// closed — a result silently lost rather than an error shown.
    public let resumableTurns: Bool
    /// How long a finished turn stays resumable. Only meaningful when
    /// `resumableTurns` is true.
    public let retentionSeconds: Int?
    /// Per-turn buffer cap; beyond it the host truncates and says so on resume.
    public let maxBufferBytes: Int?
    /// Telemetry this host can supply. Open set — unknown items are kept so a
    /// client that learns to render one needs no protocol change.
    public let telemetry: Set<String>

    public init(
        resumableTurns: Bool = false,
        retentionSeconds: Int? = nil,
        maxBufferBytes: Int? = nil,
        telemetry: Set<String> = []
    ) {
        self.resumableTurns = resumableTurns
        self.retentionSeconds = retentionSeconds
        self.maxBufferBytes = maxBufferBytes
        self.telemetry = telemetry
    }

    /// Reads the host-level `x_localis`, defaulting every absent or
    /// wrong-typed field.
    ///
    /// Wrong-typed matters as much as absent: coercing the string `"yes"` into
    /// `true` would flip the disconnect semantics on a bridge that had a bug.
    init(json: JSONValue?) {
        self.init(
            resumableTurns: json?["resumable_turns"]?.boolValue ?? false,
            retentionSeconds: json?["retention_seconds"]?.intValue,
            maxBufferBytes: json?["max_buffer_bytes"]?.intValue,
            telemetry: Set(json?["telemetry"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        )
    }
}

extension String {
    /// Shared by the catalogue parsers, which reject whitespace-only ids the
    /// same way they reject absent ones.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
