import Foundation
import LocalisModels

/// A bridge seen on the network or typed in by hand (FR-001).
///
/// A *sighting*, not a host: it carries only what the advertisement said, and
/// nothing that confers trust. There is no pin on it, no token, no `canConnect`
/// — deciding whether this is a machine we know is `recognised(presenting:among:)`,
/// which needs the certificate the bridge actually presented and the hosts on
/// file. A discovered host that could vouch for itself would be a bridge
/// asserting its own identity, which is the property pinning exists to deny.
public struct DiscoveredHost: Hashable, Sendable {
    /// How this host came to our attention. Presentation only — a manually
    /// added machine speaks the same protocol and is pinned the same way.
    public enum Source: Hashable, Sendable {
        case bonjour
        case manual
    }

    /// What the bridge calls itself, or the address for a manual entry.
    public let displayName: String
    /// Where it answers now. Expected to change: DHCP renewal, a switch to a
    /// Tailscale address.
    public let endpoint: HostEndpoint
    /// TXT `hid=` — the bridge's stable instance id, when it sends one.
    ///
    /// **Not an identity authority** (Amendment A §1.6). It relocates a machine
    /// whose certificate already matches; a clone reporting the same `hid` from
    /// a different key is a different machine.
    public let bridgeID: String?
    /// TXT `v=` — the protocol version advertised. Nil when absent or
    /// unparseable, never defaulted: a fabricated version would be compared
    /// against as though the bridge had stated it.
    public let advertisedProtocol: Int?
    public let source: Source

    // MARK: - Bonjour

    /// Builds a host from a Bonjour advertisement, or nil if it is unusable.
    ///
    /// Nil rather than throwing: one bridge advertising badly is skipped and the
    /// browse continues, so a single misbehaving machine cannot hide the others.
    init?(service: BonjourService) {
        let host = service.host.trimmed
        guard !host.isEmpty, (1...65_535).contains(service.port) else { return nil }

        displayName = service.txt[TXTKey.name]?.trimmed.nonEmpty ?? service.name
        endpoint = HostEndpoint(host: host, port: service.port)

        // Blank is absent. An empty `hid` would compare equal to another empty
        // `hid` and merge two unrelated machines during recognition.
        bridgeID = service.txt[TXTKey.bridgeID]?.trimmed.nonEmpty

        advertisedProtocol = service.txt[TXTKey.version].flatMap { Int($0.trimmed) }
        source = .bonjour
    }

    // MARK: - Manual entry

    /// Builds a host from an address the user typed (FR-001).
    ///
    /// Bonjour needs multicast, which Tailscale, a VPN and most guest networks
    /// do not carry. This is the way in for those, and it is validated exactly
    /// like any other endpoint — including the HTTPS-only rule, since a manual
    /// field is the obvious place a plaintext fallback would reappear.
    ///
    /// - Throws: `LocalisError.invalidInput(field: "endpoint")`.
    public init(manualEndpoint text: String) throws {
        let url = try EndpointValidator.validate(text)
        guard let host = url.host, !host.isEmpty else {
            throw LocalisError.invalidInput(field: "endpoint")
        }

        let port = url.port ?? Self.defaultHTTPSPort
        endpoint = HostEndpoint(host: host, port: port)
        // The address is the only distinguishing thing we have. A generic name
        // would make two manually added machines identical in the list.
        displayName = endpoint.displayText
        bridgeID = nil
        advertisedProtocol = nil
        source = .manual
    }

    private static let defaultHTTPSPort = 443

    // MARK: - Recognition

    /// Whether this sighting is a machine already on file (FR-031).
    ///
    /// Delegates to `HostRecognition`, which owns the rule. Deliberately not
    /// reimplemented here: the matching order is subtle, gets it wrong silently
    /// in both directions, and must read identically wherever it is applied.
    ///
    /// - Parameters:
    ///   - spki: the SPKI of the certificate the bridge presented on a real
    ///     connection — the trust anchor. Not something the advertisement can
    ///     claim.
    ///   - hosts: every host on file, paired or revoked.
    public func recognised(
        presenting spki: SPKIHash,
        among hosts: [LocalisHost]
    ) -> HostRecognition.Outcome {
        HostRecognition.recognise(bridgeID: bridgeID, spki: spki, among: hosts)
    }
}

/// TXT record keys from the contract (§0).
///
/// Named rather than inlined so a typo is a compile error instead of a bridge
/// that silently never matches.
enum TXTKey {
    static let version = "v"
    static let name = "name"
    static let bridgeID = "hid"
}

/// One raw Bonjour advertisement.
///
/// The wire shape, kept internal: what leaves this package is `DiscoveredHost`.
struct BonjourService: Hashable, Sendable {
    /// The service instance name — the fallback display name.
    let name: String
    let host: String
    let port: Int
    let txt: [String: String]
}

/// Source of Bonjour advertisements.
///
/// A protocol so the parsing, skipping and recognition above are testable: the
/// real implementation needs a live multicast network with a bridge on it, which
/// no CI machine has.
protocol BridgeBrowser: Sendable {
    /// Advertisements as they arrive. Finishes when browsing stops.
    func services() async -> AsyncStream<BonjourService>
    func stop() async
}

/// Browses for bridges on the local network (T024).
///
/// **The one place in this package that sees more than one machine**, and it
/// still holds no collection: hosts are emitted one at a time and the caller
/// assembles the list. Everything else here is built for a single host, which is
/// what keeps "which host is current?" from becoming a question this package can
/// answer wrongly (Amendment A, plan §1.1).
public struct BridgeDiscovery: Sendable {
    /// Bonjour service type from the contract (§0).
    public static let serviceType = "_localis._tcp"

    private let browser: any BridgeBrowser

    init(browser: any BridgeBrowser) {
        self.browser = browser
    }

    /// Bridges as they appear.
    ///
    /// Not deduplicated. A machine re-advertising after a DHCP renewal is
    /// reported again, and that repeat *is* the address change — swallowing it
    /// would strand the host at an endpoint that no longer answers.
    ///
    /// Unusable advertisements are skipped rather than surfaced: a bad one is
    /// nothing the user can act on, and ending the stream would let one
    /// misconfigured bridge hide every working one.
    public func hosts() -> AsyncStream<DiscoveredHost> {
        AsyncStream { continuation in
            let task = Task {
                for await service in await browser.services() {
                    guard let host = DiscoveredHost(service: service) else { continue }
                    continuation.yield(host)
                }
                await browser.stop()
                continuation.finish()
            }

            // Cancelling the iteration stops the browse. A browser left running
            // holds the radio awake for a stream nobody is reading.
            continuation.onTermination = { _ in
                task.cancel()
                Task { await browser.stop() }
            }
        }
    }
}
