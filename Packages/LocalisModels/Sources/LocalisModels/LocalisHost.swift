import Foundation

/// A machine running `localis-bridge`.
///
/// Identity is a **locally generated** id, fixed at pairing and stable for life
/// (FR-026). The endpoint, the display name and the pinned certificate are all
/// attributes, because all three change during normal use: DHCP hands out a new
/// address, the user renames the machine, a bridge reinstall regenerates the
/// self-signed certificate. Using any of them as identity would let one machine
/// look like two and scatter its conversation history.
///
/// **No credential field, ever** (constitution principle I). The pairing token
/// lives in the Keychain, keyed by `id`, and is never modelled here — a token on
/// this struct would ride along into every log line, snapshot and encoder that
/// touches a `LocalisHost`.
///
/// Value type: every change returns a new `LocalisHost`.
///
/// Named `LocalisHost`, not `Host`, because Foundation exports a `Host` class on
/// Darwin. A domain type called `Host` compiles inside this package but makes
/// every downstream `[Host]` annotation ambiguous — the same reason the error
/// vocabulary is `LocalisError` and not `Error`. The prefix is paid once, here.
public struct LocalisHost: Identifiable, Codable, Hashable, Sendable {
    /// Locally generated, assigned once, never derived from anything on the wire.
    public let id: HostID
    /// Initially the bridge's advertised name; the user may rename it locally.
    public let displayName: String
    /// Where the bridge currently answers. Changes on DHCP renewal or when the
    /// user switches to an overlay address.
    public let endpoint: HostEndpoint
    /// The bridge's self-reported instance id, when it sends one.
    ///
    /// Optional by protocol (Amendment A §1.6) — older bridges omit it. Used to
    /// recognise a machine that moved, and **never** as an identity authority:
    /// see `HostRecognition`.
    public let bridgeID: String?
    /// SHA-256 of the bridge's certificate SPKI, pinned at pairing.
    ///
    /// Per host, always — a shared trust store would let host A's certificate
    /// authenticate host B, which is pinning in name only (FR-028).
    public let pinnedSPKI: SPKIHash?
    public let pairingState: HostPairingState
    /// The protocol version negotiated with *this* host (FR-032).
    public let protocolVersion: Int
    /// Icon and wording only — never a behavioural branch.
    public let kind: HostKind

    public init(
        id: HostID,
        displayName: String,
        endpoint: HostEndpoint,
        bridgeID: String? = nil,
        pinnedSPKI: SPKIHash? = nil,
        pairingState: HostPairingState = .discovered,
        protocolVersion: Int = 1,
        kind: HostKind = .mac
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.bridgeID = bridgeID
        self.pinnedSPKI = pinnedSPKI
        self.pairingState = pairingState
        self.protocolVersion = protocolVersion
        self.kind = kind
    }

    /// Whether the app may open a connection to this host.
    ///
    /// Paired **and** pinned. A changed certificate fails this check with no way
    /// to override it — constitution V allows no "trust anyway" path.
    public var canConnect: Bool {
        pairingState == .paired && pinnedSPKI != nil
    }

    // MARK: - Transitions

    /// Moves to `.pairing` while the out-of-band code is being exchanged.
    public func beginningPairing() -> LocalisHost {
        with(pairingState: .pairing)
    }

    /// Completes pairing, pinning `spki` for this host alone.
    public func paired(pinning spki: SPKIHash) -> LocalisHost {
        with(pinnedSPKI: .some(spki), pairingState: .paired)
    }

    /// Drops the pinned certificate and marks the host revoked.
    ///
    /// FR-027: unpairing leaves **zero residue**. The caller is responsible for
    /// the matching Keychain entry; the pinned SPKI is cleared here so the
    /// "nothing left behind" property is assertable in a unit test.
    ///
    /// `bridgeID` deliberately survives: it is not a credential, and keeping it
    /// lets a later re-pair recognise the machine and reactivate its orphaned
    /// sessions.
    public func unpaired() -> LocalisHost {
        with(pinnedSPKI: .some(nil), pairingState: .revoked)
    }

    /// Records that the presented certificate no longer matches the pinned one.
    ///
    /// The old pin is kept so the UI can name *this* host as the one that
    /// changed; `canConnect` is already false via the state.
    public func certificateChanged() -> LocalisHost {
        with(pairingState: .certificateChanged)
    }

    public func renamed(to newName: String) -> LocalisHost {
        with(displayName: newName)
    }

    /// Follows the host to a new address — same machine, new endpoint (FR-031).
    public func relocated(to newEndpoint: HostEndpoint) -> LocalisHost {
        with(endpoint: newEndpoint)
    }

    public func withBridgeID(_ newBridgeID: String?) -> LocalisHost {
        with(bridgeID: .some(newBridgeID))
    }

    public func withProtocolVersion(_ version: Int) -> LocalisHost {
        with(protocolVersion: version)
    }

    public func withKind(_ newKind: HostKind) -> LocalisHost {
        with(kind: newKind)
    }

    /// One copy-with, so every transition above stays a single line and no field
    /// can be dropped by accident.
    ///
    /// The doubly-wrapped optionals distinguish "leave it alone" (`nil`) from
    /// "set it to nil" (`.some(nil)`).
    private func with(
        displayName: String? = nil,
        endpoint: HostEndpoint? = nil,
        bridgeID: String?? = nil,
        pinnedSPKI: SPKIHash?? = nil,
        pairingState: HostPairingState? = nil,
        protocolVersion: Int? = nil,
        kind: HostKind? = nil
    ) -> LocalisHost {
        LocalisHost(
            id: id,
            displayName: displayName ?? self.displayName,
            endpoint: endpoint ?? self.endpoint,
            bridgeID: bridgeID ?? self.bridgeID,
            pinnedSPKI: pinnedSPKI ?? self.pinnedSPKI,
            pairingState: pairingState ?? self.pairingState,
            protocolVersion: protocolVersion ?? self.protocolVersion,
            kind: kind ?? self.kind
        )
    }
}

/// Locally generated, stable-for-life host identity (FR-026).
///
/// A distinct type rather than a bare `UUID` so a host id can never be passed
/// where a session id belongs.
public struct HostID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where a bridge answers. Mutable in the sense that a `LocalisHost` can be given a new
/// one — the value itself is immutable.
public struct HostEndpoint: Hashable, Codable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// For display only. The transport builds real URLs itself.
    public var displayText: String { "\(host):\(port)" }
}

/// SHA-256 of a certificate's SubjectPublicKeyInfo, base64 encoded.
public struct SPKIHash: Hashable, Codable, Sendable {
    public let base64: String

    public init(base64: String) {
        self.base64 = base64
    }

    public init(from decoder: any Decoder) throws {
        base64 = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64)
    }
}

/// Where a host sits in the pairing lifecycle.
public enum HostPairingState: String, Codable, CaseIterable, Sendable {
    /// Seen on the network, not yet paired.
    case discovered
    /// The out-of-band code exchange is in progress.
    case pairing
    /// Paired, token in the Keychain, certificate pinned.
    case paired
    /// The user unpaired it. Sessions survive as read-only (FR-027).
    case revoked
    /// The presented certificate no longer matches the pin — connection refused
    /// with no override (constitution V).
    case certificateChanged
}

/// Icon and wording only. Deliberately not a behavioural branch: a NAS and a Mac
/// speak the identical protocol (Amendment B §8).
public enum HostKind: String, Codable, CaseIterable, Sendable {
    case mac
    case nas
    case vps
    case other
}
