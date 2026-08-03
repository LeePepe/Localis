import Foundation
import SwiftData

/// Persistent shape of a conversation.
///
/// `hostID` is the load-bearing field (FR-037): a backend name like `claude`
/// only identifies a backend *within* one machine, so every stored session
/// carries the machine it belongs to and the composite `(hostID, backendID)` is
/// what the store actually queries on.
///
/// Stored as a raw `UUID?` rather than a `HostID`: SwiftData predicates compile
/// against primitives, and a `#Predicate` over a wrapper struct is exactly the
/// kind of thing that silently degrades to an in-memory filter. The wrapper is
/// reapplied on the way out, in `StoredMapping`.
///
/// `nil` means one thing only — a row written before Amendment A, not yet
/// migrated. It never means "any machine". Unpairing does **not** clear this
/// field: a session's machine is fixed for life (FR-030), so an unpaired host's
/// conversations keep their binding and are marked `isOrphaned` instead.
@Model
final class StoredSession {
    #Index<StoredSession>([\.hostID], [\.hostID, \.backendID], [\.updatedAt])
    #Unique<StoredSession>([\.id])

    var id: UUID = UUID()
    /// Owning machine, or `nil` for a not-yet-migrated legacy row.
    var hostID: UUID?
    /// Wire identifier from that host's `/v1/models`. Unique per host only.
    var backendID: String = ""
    var title: String = ""
    var createdAt: Date = Date(timeIntervalSince1970: 0)
    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    /// The host was unpaired: read-only history, never auto-deleted (FR-027).
    ///
    /// Kept as its own column even though `statusJSON` can also spell
    /// `.orphaned`: attribution is what queries filter on, and a predicate over
    /// a JSON blob is not one SwiftData can push down to the store.
    var isOrphaned: Bool = false

    /// JSON-encoded `SessionStatus`, or `nil` for a row written before it was
    /// persisted.
    ///
    /// Only `.error(_)` genuinely needs to survive a relaunch, and it is the
    /// reason the whole enum is stored rather than a flag. A failure is a
    /// *historical fact* — nothing on next launch can re-derive it, unlike
    /// reachability, which is simply re-probed. Dropping it means the user kills
    /// the app and finds yesterday's failed conversation sitting at `idle`, with
    /// no way to tell whether their message was ever answered.
    ///
    /// The transient connection states are normalized away on read (see
    /// `StoredMapping.status(from:)`) rather than at write time, so a crash
    /// mid-stream cannot leave an un-normalizable row behind.
    var statusJSON: String?

    /// Cascade: deleting a conversation takes its transcript with it. This is
    /// the *only* cascade in the schema — unpairing a host deliberately does not
    /// delete (FR-027).
    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.session)
    var messages: [StoredMessage]? = []

    init(
        id: UUID,
        hostID: UUID?,
        backendID: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        isOrphaned: Bool = false,
        statusJSON: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.backendID = backendID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isOrphaned = isOrphaned
        self.statusJSON = statusJSON
        self.messages = []
    }
}

/// Persistent shape of one message.
///
/// A separate entity rather than a blob on the session: streaming appends a
/// chunk at a time, and rewriting a whole transcript per chunk is what makes a
/// long answer stutter (spec Edge Case: "persistence must not block the UI").
@Model
final class StoredMessage {
    #Index<StoredMessage>([\.createdAt])
    #Unique<StoredMessage>([\.id])

    var id: UUID = UUID()
    /// Raw value of `MessageRole` — stored as a string so an unknown role from
    /// a future version degrades to a decode fallback rather than a crash.
    var roleRaw: String = ""
    var text: String = ""
    var createdAt: Date = Date(timeIntervalSince1970: 0)
    var statusRaw: String = ""

    /// Background-resume bookkeeping (Amendment C §1.3). Both `nil` unless this
    /// message is an assistant turn that was streaming.
    ///
    /// `lastSeq` is optional rather than sentinel-encoded: `seq` counts from 0
    /// per turn, so `0` would silently skip the first frame and `-1` would be a
    /// sentinel impersonating a sequence number. `nil` means "no frame accepted
    /// yet", which is a different fact from "accepted frame 0".
    var turnID: String?
    var lastSeq: Int?
    /// Raw `StoredDeliveryState`. `nil` means the message never streamed, so
    /// there is nothing to reconcile on return.
    var deliveryStateRaw: String?

    /// Failure detail from `x-localis-turn-end` (contract §3.1(d)), so the app
    /// can still say *how* a turn failed after a relaunch.
    ///
    /// These are on disk for one specific reason: the user may force-quit before
    /// ever seeing the failure. Living only in the stream event would mean a turn
    /// that died while they were away comes back as a bare "Error" instead of
    /// "failed 8 minutes in, after 3 tool calls" — losing exactly the detail that
    /// tells them whether retrying is worth it. Both `nil` unless the turn failed.
    var failedAtMs: Int?
    var toolCallsCompleted: Int?

    var session: StoredSession?

    init(
        id: UUID,
        roleRaw: String,
        text: String,
        createdAt: Date,
        statusRaw: String
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.text = text
        self.createdAt = createdAt
        self.statusRaw = statusRaw
    }
}

/// Persistent shape of a backend, scoped to the host that advertised it.
///
/// Keyed by `(hostID, backendID)` for the same reason sessions are: two
/// machines can both advertise `claude`, and letting one overwrite the other is
/// the cross-host bleed FR-029 forbids.
@Model
final class StoredBackend {
    #Index<StoredBackend>([\.hostID], [\.hostID, \.backendID])

    var hostID: UUID = UUID()
    var backendID: String = ""
    var displayName: String = ""
    /// Capabilities as an open set of strings — an unrecognized capability is
    /// stored and ignored, never a decode failure (constitution IV).
    var capabilities: [String] = []

    init(hostID: UUID, backendID: String, displayName: String, capabilities: [String]) {
        self.hostID = hostID
        self.backendID = backendID
        self.displayName = displayName
        self.capabilities = capabilities
    }
}
