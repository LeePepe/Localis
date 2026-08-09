import Foundation
import LocalisModels
import TransportKit

/// Builds the transport a conversation talks to its own machine through.
///
/// **A closure rather than a protocol, unlike `HostProbing` next door.** There
/// is exactly one operation and it takes exactly one argument; a protocol would
/// be a named box around a function type, and every test double would be a
/// `struct` conforming to it in order to hold a stored closure anyway. The seam
/// exists for the same reason `HostProbing`'s does, though, and that reason is
/// the whole point: a model that constructed its own `BridgeClient` could only
/// be exercised against a real Mac, so every assertion about what the chat
/// screen does when the host answers — or refuses — would be a thing someone
/// did by hand once.
///
/// **`throws` because building the client reads the Keychain.** Not a formality:
/// a locked or unreadable Keychain must not come out as "this machine is not
/// paired", which is the one wrong answer that sends the user to re-pair — and
/// re-pairing overwrites the pin we failed to read. `HostAssembly.joined` refuses
/// to swallow it for the same reason.
typealias ChatTransportFactory = @Sendable (LocalisHost) throws -> any AgentTransport

/// The real transport: one `BridgeClient` per machine, built from that
/// machine's own pin and token (FR-028).
///
/// A namespace rather than a free `let`, so the default argument at the call
/// site reads as a choice of transport and not as a stray global.
enum BridgeTransport {
    /// `HostCredentialStore()` is constructed here rather than injected: this
    /// value *is* the production wiring, and a version of it that could be
    /// pointed at a substitute store would make "the real one" a thing callers
    /// configure. Tests replace the whole factory instead — that is what the
    /// seam is for.
    static let factory: ChatTransportFactory = { host in
        try BridgeClient(
            host: host.id,
            endpoint: host.endpoint,
            credentials: HostCredentialStore()
        )
    }
}
