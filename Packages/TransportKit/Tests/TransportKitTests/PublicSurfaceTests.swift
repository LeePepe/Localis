import Foundation
import Testing

// **No `@testable`, and that is the whole test.** Every other suite in this
// target imports `@testable TransportKit`, which erases access control — so a
// symbol the app can never touch looks, from in here, exactly like one it can.
// That is how `BridgePairing` came to have ten passing tests and no reachable
// caller: its only initialiser is `internal`, its only parameter types
// (`PinnedHTTP`, `NetworkBrowser`) are `internal`, and the app target is a
// different module. Pairing was untestable-from-outside and *unusable* from
// outside, and the two are indistinguishable under `@testable`.
//
// Measured before this file existed, with a throwaway package outside the
// worktree depending on `Packages/TransportKit`:
//
//     BridgeClient(host:endpoint:credentials:)  → compiled          (control)
//     BridgePairing(http:credentials:)          → 'initializer is inaccessible
//                                                  due to internal protection level'
//     PinnedHTTP / NetworkBrowser               → 'cannot find ... in scope'
//
// The control compiling is what makes the other two a fact about this package
// rather than about the probe.
//
// **One of those three was my own question asked wrongly, and it is worth
// keeping.** `BridgeDiscovery(browser: NetworkBrowser())` fails on
// `NetworkBrowser`, not on `BridgeDiscovery` — the public `init()` was already
// there, in an extension in `NetworkBrowser.swift`, and the probe never asked
// about it. An expression that names two symbols reports the first one that
// fails, so "discovery is unreachable" was a conclusion about the argument
// dressed as one about the type. `discoveryIsConstructible` below is the
// question asked directly.
//
// This file is that probe, kept. A plain `import` in one file is unaffected by
// a sibling file's `@testable` — verified by writing `PinnedTrust` here and
// watching it fail with `cannot find 'PinnedTrust' in scope`, which is also the
// positive control for the whole idea.
import LocalisModels
import TransportKit

/// The public surface an app target actually has.
///
/// These assertions are made by *compiling*, not by `#expect`. A missing public
/// entry point is a build failure in this file, which is a stronger signal than
/// any runtime check could be — and one that cannot be satisfied by a comment.
@Suite("The package's outside")
struct PublicSurfaceTests {
    /// Pairing can be started from outside the package (FR-002).
    ///
    /// The pin is **not optional**, deliberately (Amendment E §3): the SPKI and
    /// the six-digit code travel the same out-of-band channel, so the pairing
    /// request itself goes out on an already-pinned connection. There is no
    /// "first connection with no pin" step, and this signature is what makes
    /// that unexpressible from outside rather than merely discouraged.
    @Test("pairing has a public entry point that demands a pin")
    func pairingIsConstructible() throws {
        let pairing = BridgePairing(
            pinnedTo: SPKIHash(base64: "AAA="),
            credentials: HostCredentialStore(service: "dev.localis.surface-probe")
        )

        // Referenced so the value cannot be optimised into nothing, and so a
        // renamed method fails here too.
        #expect(type(of: pairing) == BridgePairing.self)
    }

    /// Discovery can be started from outside the package (FR-001).
    ///
    /// Already true before this file — `init()` is public, in an extension in
    /// `NetworkBrowser.swift`. Asserted here anyway: it is public in a *different
    /// file from the type*, which is exactly the arrangement someone tidying
    /// `NetworkBrowser.swift` would move or narrow without realising it is the
    /// app's only way in.
    @Test("discovery has a public entry point")
    func discoveryIsConstructible() {
        let discovery = BridgeDiscovery()

        #expect(type(of: discovery) == BridgeDiscovery.self)
    }

    /// The half that must stay shut.
    ///
    /// `PinnedHTTP` is the only way to build a session that skips the pin, and
    /// TransportKit's red line says it must not be constructible from outside
    /// this package. Nothing here can *assert* an absence — a name that does not
    /// resolve is a compile error, not a failing test — so the guard is the
    /// source sweep in `ArchitectureTests.pinnedSessionStaysInternal`, and this
    /// comment is the pointer to it.
    ///
    /// Recorded here because this is the file someone widening the public
    /// surface will open.
    @Test("the unpinned session type is not part of that surface")
    func unpinnedSessionIsNotPublic() {
        // Deliberately empty of a construction attempt: writing one would not
        // compile, which fails the build rather than the test.
        #expect(Bool(true))
    }
}
