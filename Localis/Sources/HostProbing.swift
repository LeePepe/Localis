import Foundation
import LocalisModels
import TransportKit

/// Asks a machine whether it is answering right now.
///
/// **Why this protocol exists rather than `HostListModel` building a
/// `BridgeClient` itself.** Until now nothing could put a `HostRuntimeState` in
/// front of the user: the value is deliberately not persisted (Amendment C
/// §4.2), so it cannot arrive through the repository, and every `HostRowState`
/// was built straight off disk with the `.unknown` default. The display side
/// (#35) and the reason-classifying side (#34/#45) were both finished and
/// correct, and the row still showed nothing, because the two ends were never
/// joined. This is the join.
///
/// **It is also the only way the wiring can be tested.** A model that
/// constructed its own transport could only be exercised against a real Mac,
/// which means the assertion "a rejected certificate reaches the host row"
/// would be a thing someone did by hand once. With this seam a test supplies
/// the answer and the suite can state what the row must then say — and, just as
/// importantly, the demo path can drive it without anyone touching a
/// certificate.
protocol HostProbing: Sendable {
    /// What the machine is doing right now, as far as one attempt can tell.
    ///
    /// Does not throw. A probe failing *is* the answer — every reason a host
    /// might not answer is already a `HostUnreachableReason`, and an error
    /// escaping here would make the caller decide what a thrown error means
    /// about reachability, which is the classification `HostReachability`
    /// exists to hold.
    func reachability(of host: LocalisHost) async -> HostReachability
}

/// Probes over the real transport, one connection per host.
///
/// A fresh `BridgeClient` per probe rather than a cached one: the client is
/// built from the pin in the Keychain, and a cached instance would go on
/// trusting a pin the user has since replaced by re-pairing. Probes are rare —
/// one per host per list load — so there is nothing here worth caching against
/// that risk.
struct BridgeHostProbe: HostProbing {
    private let credentials: HostCredentialStore

    init(credentials: HostCredentialStore = HostCredentialStore()) {
        self.credentials = credentials
    }

    func reachability(of host: LocalisHost) async -> HostReachability {
        // A machine that was never paired is not "unreachable" — nothing has
        // been attempted, and there is no pin to attempt it with. Reporting
        // `.offline` here would put "isn't answering" under every machine the
        // user has not paired yet, which is a claim no probe backs.
        guard host.canConnect else { return .unknown }

        do {
            let client = try BridgeClient(
                host: host.id,
                endpoint: host.endpoint,
                credentials: credentials
            )
            // `models()` rather than `probe(_:)`, and the difference matters.
            //
            // `probe` answers "can I use *this agent* on that Mac", so it
            // reports `.unreachable(reason: .offline)` when the host answers
            // but does not list the backend it was asked about. The host list
            // is not about any agent, and there is no backend to name here —
            // passing a placeholder would land in exactly that branch and
            // report every reachable Mac as offline.
            //
            // The question here is only whether the machine answered, so the
            // catalogue is requested and its contents ignored.
            _ = try await client.models()
            return .reachable
        } catch {
            // Every reason a probe can fail is already a case of
            // `HostUnreachableReason`, and `HostReachability(failure:)` is the
            // one place that decides which. Classifying here instead would put
            // a second opinion next to it — the split that let a rejected
            // certificate read as "check it's on the same network" (#45).
            guard let error = error as? LocalisError else {
                // `models()` maps everything into `LocalisError` before it
                // escapes. Anything else is a break in that guarantee rather
                // than a fact about the machine, so nothing is claimed about
                // reachability — `.unknown` says "we did not establish
                // anything", which is true.
                return .unknown
            }
            return HostReachability(failure: error)
        }
    }
}

/// Answers from a launch argument instead of from a network.
///
/// **What this is for.** The acceptance for #41 is a sentence on a host card:
/// a Mac whose certificate we refused must say *"This Mac's identity has
/// changed…"* and must not say *"This Mac isn't answering…"*. Producing that
/// state for real means changing a Mac's certificate — which is a thing someone
/// does once, badly, and never again, so the check would in practice never be
/// repeated. With this, it is `simctl launch` and a glance.
///
/// **Why it is a probe rather than a fixture.** `DemoSeed` writes records, and
/// `HostRuntimeState` is deliberately never persisted (Amendment C §4.2) — the
/// value cannot be seeded, because there is nowhere to seed it to. Substituting
/// here is the only way in, and it substitutes the *whole* probe, so everything
/// downstream of it — the reason mapping, `HostRowState`, the card — is the same
/// code the real probe drives. Nothing about the display path is special-cased
/// for the demo.
///
/// **Why it cannot fire in production**, same argument as `DemoSeed`: launch
/// arguments come from Xcode schemes, `simctl launch`, and `XCUIApplication`,
/// none of which exist for a user-installed build, and `RootView` only
/// constructs this when one is present.
struct DemoHostProbe: HostProbing {
    /// `xcrun simctl launch <device> com.leepepe.localis -LocalisDemoUnreachable certificateRejected`
    ///
    /// Read through `UserDefaults` rather than by scanning `arguments`, because
    /// this one carries a value and that is the reader which pairs `-key` with
    /// the token after it.
    static let defaultsKey = "LocalisDemoUnreachable"

    static var requestedReason: HostUnreachableReason? {
        reason(named: UserDefaults.standard.string(forKey: defaultsKey))
    }

    /// The mapping half of `requestedReason`, split out so it can be stated
    /// without touching `UserDefaults.standard`.
    ///
    /// **Extracted for the test, and the extraction is not the whole test.**
    /// Asserting only this would leave the join — the key name, and the fact
    /// that anything reads it at all — unasserted, which is the same shape that
    /// let #48's display chain sit broken while both of its ends were green.
    /// `DemoProbeReasonTests` states this function's rule and then goes through
    /// `requestedReason` once against the real defaults, so a renamed key
    /// cannot stay quiet.
    ///
    /// - Parameter name: the raw launch-argument value, or `nil` when none was
    ///   passed — which is every shipped build.
    static func reason(named name: String?) -> HostUnreachableReason? {
        switch name {
        case "offline": .offline
        case "certificateRejected": .certificateRejected
        case "unauthorized": .unauthorized
        case "unsupportedProtocol": .unsupportedProtocol
        // Includes an unrecognised value. It reports `.unknown`, so the card
        // shows no sentence — visibly *not* the state that was asked for,
        // rather than a different failure that could be mistaken for it. A
        // fallback of `.offline` would answer a request for
        // `certificateRejected` with the one sentence the acceptance says must
        // not appear, and read as the wiring being broken.
        //
        // Asserted by `DemoProbeReasonTests.unrecognisedReasonDoesNotFallBack`,
        // with the positive control beside it — a mapping that returned `nil`
        // for *everything* would satisfy that assertion forever while the demo
        // device silently stopped working.
        default: nil
        }
    }

    let reason: HostUnreachableReason

    func reachability(of host: LocalisHost) async -> HostReachability {
        // The same guard the real probe applies, so an unpaired fixture stays
        // blank here as it would there. That contrast is the point of looking:
        // one machine carrying the sentence beside one that does not is
        // evidence the reason travelled, where two identical cards would not be.
        guard host.canConnect else { return .unknown }
        return .unreachable(reason: reason)
    }
}
