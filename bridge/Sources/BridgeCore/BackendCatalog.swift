import Foundation

/// One backend this host can run (contract §2).
///
/// **Capabilities, not identity.** The iOS side switches features on the
/// strings in `capabilities` and is forbidden from branching on `id`
/// (constitution IV) — so a sixth backend is a sixth entry in this list and
/// nothing else. Anything the phone needs to decide must be expressible here.
public struct BackendDescriptor: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let capabilities: [String]
    public let available: Bool
    /// Why not, when `available` is false. A code from the contract's
    /// vocabulary — never a sentence, and never a path.
    public let unavailableReason: String?

    public init(
        id: String,
        displayName: String,
        capabilities: [String],
        available: Bool,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.available = available
        self.unavailableReason = unavailableReason
    }

    /// The `data` entry, in OpenAI's shape plus the `x_localis` object.
    public var json: [String: any Sendable] {
        var extensions: [String: any Sendable] = [
            "display_name": displayName,
            "capabilities": capabilities,
            "available": available,
        ]
        // Present only when it means something. An `unavailable_reason` sitting
        // next to `available: true` is a contradiction the client would have to
        // pick a side on.
        if let unavailableReason, !available {
            extensions["unavailable_reason"] = unavailableReason
        }

        return [
            "id": id,
            "object": "model",
            "owned_by": "localis",
            "x_localis": extensions,
        ]
    }
}

/// What this host can do, and which backends it has (contract §2 / §2.1).
public struct BackendCatalog: Sendable {
    public let backends: [BackendDescriptor]

    /// Whether a turn survives the phone dropping off the network.
    ///
    /// **The client defaults this to false when the field is absent**, which is
    /// the safe direction: an old bridge that never heard of resume gets the
    /// old "disconnect cancels the turn" semantics rather than a client waiting
    /// for a result nobody is keeping.
    public let resumableTurns: Bool
    public let retentionSeconds: Int
    public let maxBufferBytes: Int
    public let telemetry: [String]

    public init(
        backends: [BackendDescriptor],
        resumableTurns: Bool = false,
        retentionSeconds: Int = 600,
        maxBufferBytes: Int = 4 * 1024 * 1024,
        telemetry: [String] = ["usage", "activity", "tool_calls"]
    ) {
        self.backends = backends
        self.resumableTurns = resumableTurns
        self.retentionSeconds = retentionSeconds
        self.maxBufferBytes = maxBufferBytes
        self.telemetry = telemetry
    }

    /// The whole `GET /v1/models` body.
    public var json: [String: any Sendable] {
        [
            "object": "list",
            "x_localis": [
                "resumable_turns": resumableTurns,
                "retention_seconds": retentionSeconds,
                "max_buffer_bytes": maxBufferBytes,
                "telemetry": telemetry,
            ] as [String: any Sendable],
            "data": backends.map(\.json),
        ]
    }

    /// Looks a backend up by the id the client sent.
    public func backend(id: String) -> BackendDescriptor? {
        backends.first { $0.id == id }
    }
}
