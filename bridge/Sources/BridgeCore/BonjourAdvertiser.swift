import Foundation
import dnssd

/// Advertises this bridge as `_localis._tcp` so the iOS side can find it
/// (contract §0).
///
/// **Registration, not browsing.** The phone browses; this only announces. The
/// TXT contents and the name limits live in ``BonjourTXT``, which is testable
/// without a network — what is left here is the `mDNSResponder` handshake,
/// which is not.
///
/// Uses the `dnssd` C API directly rather than `NWListener`: this process
/// already owns its listening socket through NIO, and `NWListener` wants to own
/// one itself. Registering a service for a port held by someone else is exactly
/// what `DNSServiceRegister` is for.
public final class BonjourAdvertiser: @unchecked Sendable {
    /// The service type from the contract. Must match `BridgeDiscovery.serviceType`
    /// on the iOS side, which browses for this literal.
    public static let serviceType = "_localis._tcp"

    private var service: DNSServiceRef?
    private let lock = NSLock()

    public init() {}

    /// Announces the bridge on the local network.
    ///
    /// Failures are reported, never swallowed: a bridge that silently fails to
    /// advertise looks exactly like a bridge on a network without multicast,
    /// and the user is left typing an address by hand with no idea why.
    /// The caller decides whether that is fatal — it is not, since manual entry
    /// still works.
    public func start(port: Int, name: String, instanceID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard service == nil else { throw Failure.alreadyAdvertising }

        let txt = BonjourTXT.encode(
            BonjourTXT.record(version: BridgeProtocol.version, name: name, instanceID: instanceID)
        )
        let serviceName = BonjourTXT.serviceName(for: name)

        var reference: DNSServiceRef?
        let status = txt.withUnsafeBufferPointer { buffer in
            DNSServiceRegister(
                &reference,
                0,
                0,
                serviceName,
                Self.serviceType,
                nil,
                nil,
                // Network byte order: the API takes the port as it appears on
                // the wire, and passing host order advertises a byte-swapped
                // port that nothing can connect to.
                UInt16(port).bigEndian,
                UInt16(buffer.count),
                buffer.baseAddress,
                nil,
                nil
            )
        }

        guard status == kDNSServiceErr_NoError else {
            throw Failure.registrationFailed(status: Int(status))
        }

        service = reference
    }

    /// Withdraws the advertisement.
    ///
    /// `mDNSResponder` drops a registration when its owning process exits, so
    /// this matters for the restart case: an entry left behind points the phone
    /// at a port nothing is listening on, and the failure surfaces as a TLS
    /// timeout rather than as "that machine is gone".
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard let reference = service else { return }
        DNSServiceRefDeallocate(reference)
        service = nil
    }

    deinit {
        if let reference = service {
            DNSServiceRefDeallocate(reference)
        }
    }

    public enum Failure: Error, Equatable {
        case alreadyAdvertising
        /// A `kDNSServiceErr_*` code. Reported as a number rather than a
        /// message: the codes are documented, and the strings are not ours.
        case registrationFailed(status: Int)
    }
}
