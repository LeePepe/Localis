import Foundation

/// What a bridge claims about itself on the network.
///
/// Declared here rather than in TransportKit so the adoption rule can live
/// beside `LocalisHost` without this package depending on the transport. The
/// concrete advertisement — `DiscoveredHost`, parsed from a Bonjour TXT record —
/// conforms from the other side.
///
/// **Every value in here is unauthenticated.** Anything on the LAN can
/// broadcast any name, any bridge id, any protocol number, and nothing has
/// presented a certificate yet. The protocol exists to make that fact hard to
/// forget at the one call site where it matters: the moment these claims turn
/// into a record we keep.
public protocol HostAdvertisement {
    /// The bridge's advertised name. A label; the user may rename it later.
    var displayName: String { get }
    /// Where it says it answers.
    var endpoint: HostEndpoint { get }
    /// Its self-reported instance id, when it sends one. Never an identity
    /// authority — see `HostRecognition`.
    var bridgeID: String? { get }
    /// The protocol version it advertises, absent on bridges predating the
    /// field (Amendment A §1.6).
    var advertisedProtocol: Int?  { get }
}

extension LocalisHost {
    /// Creates the record for a machine just seen on the network.
    ///
    /// This is the *only* way a `LocalisHost` comes into existence outside
    /// deserialisation: every other member returns a modified copy, so without
    /// it the type was a room with no door. Pairing, pinning and persistence
    /// all start from a host produced here.
    ///
    /// Three things deliberately do **not** come from the advertisement:
    ///
    /// - **Identity.** A fresh `HostID` is minted locally (FR-026). Deriving it
    ///   from `bridgeID` would let a machine pick its own id, and picking
    ///   *someone else's* would be equally available — one broadcast and a
    ///   stranger inherits another Mac's history.
    /// - **`pairingState`.** Always `.discovered`. There is no code exchange
    ///   behind an advertisement, so any other value would be a trust decision
    ///   made on a stranger's say-so.
    /// - **`pinnedSPKI`.** Always `nil`. A pin may only be taken from a
    ///   certificate presented on a real connection (FR-028), and no connection
    ///   has happened. `canConnect` is therefore false on every adopted host,
    ///   which is the property that keeps this from being a way in.
    ///
    /// A missing `advertisedProtocol` is read as 1 rather than refused: a
    /// bridge predating the field is one the app can talk to, and a host we
    /// decline to record is a host the user cannot see or be told about.
    public init(adopting advertisement: some HostAdvertisement) {
        self.init(
            id: HostID(),
            displayName: advertisement.displayName,
            endpoint: advertisement.endpoint,
            bridgeID: advertisement.bridgeID,
            pinnedSPKI: nil,
            pairingState: .discovered,
            protocolVersion: advertisement.advertisedProtocol ?? 1,
            kind: .mac
        )
    }
}
