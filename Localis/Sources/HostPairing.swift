import Foundation
import LocalisModels
import TransportKit
import UIKit

/// Exchanges the six-digit code for a token, pinning the certificate the user
/// read off the Mac.
///
/// **Why this protocol exists rather than `HostPairingModel` building a
/// `BridgePairing` itself** — the same argument `HostProbing` makes, and it
/// applies verbatim. A model that constructed its own transport could only be
/// exercised against a real Mac showing a real pairing code, so "a wrong code
/// leaves no residue" and "a certificate that does not match is refused, and
/// named as such" would be acceptances someone performed by hand once. The
/// second one is worse than that: producing it for real means changing a Mac's
/// certificate, which is an acceptance nobody performs twice.
///
/// **The device's own name and id are deliberately not parameters.** They are
/// the same on every pairing this app ever performs and have nothing to do with
/// which Mac is being paired, so threading them through the screen would give a
/// test somewhere the chance to vary them and assert something about a value the
/// user cannot influence. `BridgeHostPairing` supplies them; a fake needs no
/// device at all.
protocol HostPairing: Sendable {
    /// - Parameter spki: the fingerprint the user read off the Mac's own
    ///   output. It is both the pin this request goes out under and the pin
    ///   recorded on success — `BridgePairing` holds it once, so a connection
    ///   made under one certificate cannot record another.
    /// - Returns: what the bridge said about itself. Never a credential: the
    ///   token goes straight to the Keychain inside `BridgePairing`.
    /// - Throws: `LocalisError`. **Deliberately throwing where `HostProbing`
    ///   does not.** A probe failing *is* its answer, but here the reason is the
    ///   whole point of the screen — a wrong code, a dead session and a changed
    ///   certificate demand three different actions from the user, and a
    ///   swallowed error collapses them into one.
    func pair(
        host: HostID,
        endpoint: HostEndpoint,
        code: String,
        pinning spki: SPKIHash
    ) async throws -> PairedBridge
}

/// What a bridge said about itself when it accepted the code.
///
/// **Not `BridgePairing.Result`, and not by preference.** That type is public
/// but its memberwise initialiser is not, so nothing outside TransportKit can
/// construct one — verified by compiling the call from a throwaway package
/// against the real module, which fails with *"initializer is inaccessible due
/// to 'internal' protection level"*. A seam whose return type only the real
/// implementation can produce is not a seam: every test would have to pair
/// against a live Mac, which is the situation the protocol exists to escape.
///
/// So the boundary owns its own value and `BridgeHostPairing` translates. The
/// translation is one initialiser, below, and it is the only place the two
/// shapes have to agree.
struct PairedBridge: Hashable, Sendable {
    /// The Mac's name for itself. Empty when it has none — the caller decides
    /// what to do about that rather than being handed a substitute.
    let bridgeName: String
    let protocolVersion: Int
    /// Absent on bridges predating the field (Amendment A §1.6).
    let bridgeID: String?

    init(bridgeName: String, protocolVersion: Int, bridgeID: String?) {
        self.bridgeName = bridgeName
        self.protocolVersion = protocolVersion
        self.bridgeID = bridgeID
    }

    /// Every field of the transport's answer, carried across unchanged.
    ///
    /// Spelled out field by field rather than stored whole: if `Result` gains a
    /// field, this keeps compiling and the new field is silently dropped — so
    /// the one thing to check when the contract changes is this initialiser.
    init(_ result: BridgePairing.Result) {
        self.init(
            bridgeName: result.bridgeName,
            protocolVersion: result.protocolVersion,
            bridgeID: result.bridgeID
        )
    }
}

/// Pairs over the real transport.
///
/// A fresh `BridgePairing` per attempt, because the pin is per attempt: the
/// value the user just typed is what the connection is made under, and a cached
/// instance would carry the previous attempt's fingerprint into this one — which
/// is exactly the substitution pinning exists to catch.
struct BridgeHostPairing: HostPairing {
    private let credentials: HostCredentialStore
    private let device: DeviceIdentity

    init(
        credentials: HostCredentialStore = HostCredentialStore(),
        device: DeviceIdentity
    ) {
        self.credentials = credentials
        self.device = device
    }

    /// Reads this device's identity, which is why it is `@MainActor`.
    ///
    /// A separate initialiser rather than a default argument on the one above:
    /// a default of `.current` would make every construction site main-actor
    /// bound, including the ones in tests that have no business touching
    /// `UIDevice`.
    @MainActor
    init(credentials: HostCredentialStore = HostCredentialStore()) {
        self.init(credentials: credentials, device: .current)
    }

    func pair(
        host: HostID,
        endpoint: HostEndpoint,
        code: String,
        pinning spki: SPKIHash
    ) async throws -> PairedBridge {
        let result = try await BridgePairing(pinnedTo: spki, credentials: credentials).pair(
            host: host,
            endpoint: endpoint,
            code: code,
            deviceName: device.name,
            deviceID: device.id
        )
        return PairedBridge(result)
    }
}

/// How this device names itself to a Mac it is pairing with (contract §1).
///
/// The Mac lists paired devices by these two values, so both have to mean the
/// same thing on every pairing: a name that changes reads as a second phone, and
/// an id that changes *is* a second phone as far as the bridge's token store is
/// concerned — every re-pair would leave a live token behind for a device that
/// no longer exists.
struct DeviceIdentity: Sendable {
    /// Shown on the Mac. A label, never used to match anything.
    let name: String
    /// Stable for the life of the install.
    let id: UUID

    /// This device.
    ///
    /// **`@MainActor` because `UIDevice.current` is.** Reading it from a
    /// nonisolated `static var` compiles under Swift 6 with a warning rather
    /// than an error — measured, not assumed, and nothing in this project sets
    /// `SWIFT_TREAT_WARNINGS_AS_ERRORS` — but the warning is describing a real
    /// data race, and the fix costs one annotation. `BridgeHostPairing` is built
    /// on the main actor by the screen that pairs, so no call site has to change.
    ///
    /// **Not `identifierForVendor`**, which is the obvious choice and is nil
    /// until the device is unlocked after a restart. A nil there would have to
    /// be replaced by something, and the only thing available is a fresh UUID —
    /// i.e. the failure mode is "silently pair as a new device", which is the
    /// one outcome this value exists to prevent. A UUID minted once and kept is
    /// stable in exactly the cases that matter and has no nil case at all.
    @MainActor
    static var current: DeviceIdentity {
        DeviceIdentity(
            // Under iOS 16+ this is the device *model* unless the app holds the
            // user-assigned-name entitlement, which Localis does not. That is
            // fine — it is a label on the Mac's device list, not an identity —
            // and it is deliberately not made up here, so what the Mac shows is
            // whatever the OS is willing to say.
            name: UIDevice.current.name,
            id: persistedID(in: .standard)
        )
    }

    static let defaultsKey = "LocalisDeviceID"

    /// The stored id, minting and storing one on first use.
    ///
    /// Takes the store rather than reaching for `.standard`, so a test can state
    /// the rule — same id on the second read — without writing into the
    /// developer's own defaults.
    static func persistedID(in defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: defaultsKey), let existing = UUID(uuidString: raw) {
            return existing
        }
        let minted = UUID()
        defaults.set(minted.uuidString, forKey: defaultsKey)
        return minted
    }
}

/// Bridges appearing on the local network.
///
/// A seam for the same reason `BridgeDiscovery` has one inside its own package:
/// the real implementation needs a live multicast network with a Mac on it, and
/// a unit test that constructed it would start an `NWBrowser` and then assert
/// against whatever happened to be on the developer's LAN.
protocol HostDiscovering: Sendable {
    /// Sightings as they arrive. Finishes when browsing stops.
    func hosts() -> AsyncStream<DiscoveredHost>
}

/// Discovery over Bonjour.
struct BonjourHostDiscovery: HostDiscovering {
    func hosts() -> AsyncStream<DiscoveredHost> {
        BridgeDiscovery().hosts()
    }
}

extension DiscoveredHost {
    /// Which machine this sighting is, as far as a browse list is concerned.
    ///
    /// **Here rather than on `HostPairingModel` because a `ForEach` key cannot
    /// be actor-isolated.** The model is `@MainActor`, and a static on it
    /// inherits that isolation — `\.identity` as a key path into an isolated
    /// member does not typecheck from a `View`'s body. An extension on the value
    /// is nonisolated, which is also what it should be: this is a property of
    /// the sighting, not of the screen looking at it.
    ///
    /// `HostPairingModel.isSameMachine` is defined as equality of this, and the
    /// screen keys its rows on it, so the list's collapsing rule and the view's
    /// row identity are one thing rather than two that agree. See that function
    /// for what the rule is and what it deliberately costs.
    ///
    /// Namespaced by which of the two it is, so a bridge whose `hid` happens to
    /// read like `host:port` cannot collide with a machine actually at that
    /// address. Cheap to state; the alternative is a collision nobody would
    /// reproduce.
    var identity: String {
        guard let bridgeID else { return "endpoint:\(endpoint.displayText)" }
        return "hid:\(bridgeID)"
    }
}
