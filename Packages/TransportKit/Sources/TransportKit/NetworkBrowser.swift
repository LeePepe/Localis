import Foundation
import Network

/// The real Bonjour browser, backed by `NWBrowser` (T024).
///
/// Kept behind `BridgeBrowser` and deliberately thin: everything worth a test —
/// TXT parsing, skipping a bad advertisement, recognising a machine that moved —
/// lives on the other side of that seam, because this side needs a live
/// multicast network with a bridge on it and cannot run in CI.
///
/// **Resolution happens here.** `NWBrowser` reports a service *name*, not an
/// address; the host and port come from opening a connection to that name and
/// reading the path it resolved to. Without this step the endpoint would be a
/// Bonjour name that only works on the link it was found on — and would break
/// the moment the user moved to the Tailscale address.
actor NetworkBrowser: BridgeBrowser {
    private let browser: NWBrowser
    private var resolvers: Set<ObjectIdentifier> = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var continuation: AsyncStream<BonjourService>.Continuation?
    private var isStopped = false

    init(serviceType: String = BridgeDiscovery.serviceType) {
        let parameters = NWParameters.tcp
        // The bridge may be reached over a VPN or Thunderbolt bridge, not only
        // Wi-Fi. Restricting the interface here would make discovery fail in
        // exactly the setups the manual-address path exists to rescue.
        parameters.includePeerToPeer = true

        browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )
    }

    func services() async -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            self.continuation = continuation

            browser.browseResultsChangedHandler = { results, _ in
                // The full set on every change, not a delta: re-reporting a
                // machine that is still there is harmless (the stream is not
                // deduplicated by design), whereas missing one is not.
                for result in results {
                    Task { await self.resolve(result) }
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    // A browser that has failed will not recover on its own, and
                    // a stream that never finishes leaves the caller waiting on
                    // a machine that will never appear.
                    Task { await self.finish() }
                default:
                    break
                }
            }

            browser.start(queue: .global(qos: .utility))
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

        browser.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Resolution

    /// Turns one browse result into an addressable service.
    ///
    /// The TXT record arrives with the browse result; the host and port need a
    /// connection, because that is the only thing that resolves a Bonjour name
    /// to something routable.
    private func resolve(_ result: NWBrowser.Result) {
        guard !isStopped else { return }
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        let txt: [String: String]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        } else {
            // A bridge that advertises no TXT is still discoverable — every key
            // in it is optional, and the defaults are handled downstream.
            txt = [:]
        }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        let token = ObjectIdentifier(connection)

        // One resolution per service at a time. `browseResultsChangedHandler`
        // fires on every change with the whole set, so without this a single
        // machine would open a connection per callback.
        guard resolvers.insert(token).inserted else { return }
        connections[token] = connection

        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                guard case .hostPort(let host, let port) = connection?.currentPath?.remoteEndpoint else {
                    Task { await self.finishResolving(token) }
                    return
                }
                Task { await self.emit(name: name, host: Self.text(of: host), port: Int(port.rawValue), txt: txt) }
                Task { await self.finishResolving(token) }
            case .failed, .cancelled:
                // Advertised but not answering — skip it. Surfacing an
                // unreachable row gives the user nothing to act on.
                Task { await self.finishResolving(token) }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))
    }

    private func emit(name: String, host: String, port: Int, txt: [String: String]) {
        guard !isStopped else { return }
        continuation?.yield(BonjourService(name: name, host: host, port: port, txt: txt))
    }

    private func finishResolving(_ token: ObjectIdentifier) {
        connections[token]?.cancel()
        connections[token] = nil
        resolvers.remove(token)
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
    }

    /// The address as text, without the interface suffix.
    ///
    /// A link-local IPv6 address resolves as `fe80::1%en0`; carrying the `%en0`
    /// into a URL makes it unparseable later, far from here.
    private static func text(of host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        @unknown default:
            return ""
        }
    }
}

public extension BridgeDiscovery {
    /// Discovery over the local network.
    init() {
        self.init(browser: NetworkBrowser())
    }
}
