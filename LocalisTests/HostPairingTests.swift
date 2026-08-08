import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// Pairing, from the screen's side: what reaches the store, what reaches the
/// Keychain, and what the user is told when it fails.
///
/// **Why this suite is in the app target and not in TransportKit.**
/// `BridgePairingTests` proves the exchange — a correct code returns a token, a
/// wrong one writes nothing, a refused certificate is named rather than reported
/// as an outage. Not one of those tests can fail if the app never calls
/// `pair(...)`, which is exactly the state this task found the project in:
/// `BridgePairing` was correct, complete and had no production caller, so every
/// host the app could produce stayed `.discovered` for life and the only
/// `.paired` record anyone had seen was `DemoSeed` writing the state directly.
/// A transport that pairs correctly and an app that never asks are
/// indistinguishable from the user's side — both show "Not paired" forever.
///
/// So these tests assert the *app's* behaviour around the call: which record the
/// exchange belongs to, what the record says afterwards, and — the half that
/// goes wrong silently — what a failure leaves behind.
@Suite("Pairing a Mac from the app")
@MainActor
struct HostPairingTests {
    // MARK: - Fixtures

    /// A 32-byte value, which is what a SHA-256 fingerprint is.
    ///
    /// Spelled as bytes rather than as a short literal like `"AAA="` on purpose:
    /// `validatedFingerprint` refuses anything that is not 32 bytes, so a
    /// shorter fixture would make every test here fail on input validation
    /// before reaching the subject, and the temptation would then be to loosen
    /// the rule rather than fix the fixture.
    private static func fingerprint(_ byte: UInt8 = 1) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
    }

    private static func pin(_ byte: UInt8 = 1) -> SPKIHash {
        SPKIHash(base64: fingerprint(byte))
    }

    /// A sighting, through the public manual initialiser.
    ///
    /// The Bonjour initialiser — the only one that reads a `hid=` into
    /// `bridgeID` — is internal to TransportKit, so from the app target every
    /// sighting has `bridgeID == nil`. That is not a gap in the fixture: it is
    /// the shape the *manual* path really has, and it is the path this screen
    /// adds. Recognition's pin clause is what carries these tests, which is also
    /// what carries a manually added machine in production.
    private static func sighting(at host: String = "mac.local", port: Int = 8443) throws -> DiscoveredHost {
        try DiscoveredHost(manualEndpoint: "https://\(host):\(port)")
    }

    private static func repository() throws -> SwiftDataSessionRepository {
        SwiftDataSessionRepository(container: try SessionStoreContainer.inMemory())
    }

    /// A machine already on file, paired, with its pin in the Keychain fake.
    ///
    /// Written through both halves because that is how a paired machine really
    /// exists: the store holds the record and the Keychain holds the pin, and a
    /// fixture that set only one would be testing a state the app cannot reach.
    @discardableResult
    private static func recordPaired(
        _ sighting: DiscoveredHost,
        pinnedTo spki: SPKIHash,
        in repository: SwiftDataSessionRepository,
        credentials: SpyCredentials
    ) async throws -> LocalisHost {
        let host = LocalisHost(adopting: sighting).beginningPairing().paired(pinning: spki)
        try await repository.save(host)
        credentials.record(pin: spki, token: "existing", for: host.id)
        return host
    }

    /// A Keychain stand-in that only ever gets written to by `FakePairing`.
    ///
    /// **What this fake can and cannot testify to.** It mirrors `BridgePairing`'s
    /// own rule — credentials written on success, never on failure — so a test
    /// asserting "nothing was written" here is asserting about the model's flow,
    /// not re-proving the transport. That the *real* pairing writes nothing on a
    /// rejected code is stated in `BridgePairingTests`, against a real
    /// `HostCredentialStore`. Said plainly because a fake that decides its own
    /// answer looks exactly like evidence.
    ///
    /// Passed explicitly at every construction site rather than left to the
    /// default. The default is the **real** Keychain, and a test that quietly
    /// reaches it fails differently in CI than on a developer's machine.
    final class SpyCredentials: PinReading, @unchecked Sendable {
        private let lock = NSLock()
        private var storedPins: [HostID: SPKIHash] = [:]
        private var storedTokens: [HostID: String] = [:]

        var pins: [HostID: SPKIHash] { lock.withLock { storedPins } }
        var tokens: [HostID: String] { lock.withLock { storedTokens } }

        func pin(for host: HostID) throws -> SPKIHash? {
            lock.withLock { storedPins[host] }
        }

        func record(pin: SPKIHash, token: String, for host: HostID) {
            lock.withLock {
                storedPins[host] = pin
                storedTokens[host] = token
            }
        }
    }

    /// The exchange, scripted.
    ///
    /// Writes to `SpyCredentials` only on the success branch, so a test reading
    /// the spy is reading the shape `BridgePairing` produces rather than a
    /// convenience.
    final class FakePairing: HostPairing, @unchecked Sendable {
        struct Call: Sendable {
            let host: HostID
            let endpoint: HostEndpoint
            let code: String
            let spki: SPKIHash
        }

        private let lock = NSLock()
        private let outcome: Result<PairedBridge, LocalisError>
        private let credentials: SpyCredentials
        private var recorded: [Call] = []

        init(
            credentials: SpyCredentials,
            outcome: Result<PairedBridge, LocalisError> = .success(
                PairedBridge(bridgeName: "", protocolVersion: 1, bridgeID: nil)
            )
        ) {
            self.credentials = credentials
            self.outcome = outcome
        }

        var calls: [Call] { lock.withLock { recorded } }

        func pair(
            host: HostID,
            endpoint: HostEndpoint,
            code: String,
            pinning spki: SPKIHash
        ) async throws -> PairedBridge {
            lock.withLock {
                recorded.append(Call(host: host, endpoint: endpoint, code: code, spki: spki))
            }
            switch outcome {
            case .success(let bridge):
                credentials.record(pin: spki, token: "token-\(host)", for: host)
                return bridge
            case .failure(let error):
                throw error
            }
        }
    }

    /// Discovery that yields a fixed list and finishes.
    ///
    /// The real one needs a live multicast network with a Mac on it; a test
    /// using it would start an `NWBrowser` and assert against whatever happened
    /// to be on the developer's LAN.
    private struct ScriptedDiscovery: HostDiscovering {
        let sightings: [DiscoveredHost]

        func hosts() -> AsyncStream<DiscoveredHost> {
            AsyncStream { continuation in
                for sighting in sightings { continuation.yield(sighting) }
                continuation.finish()
            }
        }
    }

    private static func model(
        repository: SwiftDataSessionRepository,
        pairing: FakePairing,
        credentials: SpyCredentials,
        sightings: [DiscoveredHost] = []
    ) -> HostPairingModel {
        HostPairingModel(
            repository: repository,
            pairing: pairing,
            discovery: ScriptedDiscovery(sightings: sightings),
            credentials: credentials
        )
    }

    // MARK: - The happy path

    @Test("a correct code leaves a machine that is paired and connectable")
    func pairingProducesAConnectableHost() async throws {
        let repository = try Self.repository()
        let credentials = SpyCredentials()
        let pairing = FakePairing(
            credentials: credentials,
            outcome: .success(
                PairedBridge(bridgeName: "Tian's MacBook Pro", protocolVersion: 1, bridgeID: "bridge-abc")
            )
        )
        let model = Self.model(repository: repository, pairing: pairing, credentials: credentials)

        await model.pair(with: try Self.sighting(), code: "418302", fingerprint: Self.fingerprint())

        #expect(model.failure == nil)
        let id = try #require(model.pairedHost)

        // **Read back through `HostAssembly`, not off the store.** The store has
        // no pin column, so a record read straight from it always has
        // `canConnect == false` — asserting on that record would pass equally
        // for a pairing that recorded nothing at all. The join is where the two
        // halves of a paired machine meet, and `canConnect` is the only thing
        // that says the user can now use this Mac.
        let assembly = HostAssembly(repository: repository, credentials: credentials)
        let host = try #require(await assembly.host(id: id))
        #expect(host.pairingState == .paired)
        #expect(host.canConnect)
        #expect(credentials.pins[id] == Self.pin())
        #expect(model.pairingWith == nil)
    }

    @Test("the code and the fingerprint reach the transport unchanged")
    func exchangeCarriesWhatTheUserTyped() async throws {
        let credentials = SpyCredentials()
        let pairing = FakePairing(credentials: credentials)
        let model = Self.model(
            repository: try Self.repository(), pairing: pairing, credentials: credentials
        )

        // Padded with the whitespace a terminal paste carries. Both values are
        // read off a Mac's screen, and one that arrives with a stray newline
        // must pair rather than fail — the alternative sends the user to retype
        // a code that was correct, spending one of the five attempts that
        // invalidate the session.
        await model.pair(
            with: try Self.sighting(),
            code: " 418302\n",
            fingerprint: "  " + Self.fingerprint() + "\n"
        )

        #expect(model.failure == nil)
        let call = try #require(pairing.calls.first)
        #expect(call.code == "418302")
        #expect(call.spki == Self.pin())
        #expect(call.endpoint == HostEndpoint(host: "mac.local", port: 8443))
    }

    // MARK: - Failure leaves nothing behind

    @Test("a wrong code leaves the machine unpaired, with no credential recorded")
    func wrongCodeRollsBackAndWritesNothing() async throws {
        let repository = try Self.repository()
        let credentials = SpyCredentials()
        let pairing = FakePairing(credentials: credentials, outcome: .failure(.pairingCodeRejected))
        let model = Self.model(repository: repository, pairing: pairing, credentials: credentials)

        await model.pair(with: try Self.sighting(), code: "000000", fingerprint: Self.fingerprint())

        #expect(model.pairedHost == nil)

        // **The record must not be left at `.pairing`.** It is written before
        // the request so the row can read "Pairing…", and a rollback that missed
        // this would leave a machine stuck mid-exchange forever — a state no
        // retry clears and nothing on screen explains.
        let stored = try #require(await repository.hosts().first)
        #expect(stored.pairingState == .discovered)

        // Zero residue. A pin written for an attempt that never authenticated is
        // a trust anchor for a machine we did not successfully talk to, and it
        // would sit in the Keychain looking exactly like a legitimate one.
        #expect(credentials.pins.isEmpty)
        #expect(credentials.tokens.isEmpty)
    }

    @Test("a failed re-pair leaves a working machine working")
    func failureRollsBackToWhatWasThereBefore() async throws {
        // The rollback restores the record's *previous* state, not `.discovered`.
        // For a first pairing those are the same value, which is why every other
        // failure test here would stay green if the rollback hardcoded
        // `.discovered` — and this one would not. A mistyped code on a Mac the
        // user is already paired with must not take that Mac away from them.
        let repository = try Self.repository()
        let credentials = SpyCredentials()
        let sighting = try Self.sighting()
        let already = try await Self.recordPaired(
            sighting, pinnedTo: Self.pin(), in: repository, credentials: credentials
        )

        let pairing = FakePairing(credentials: credentials, outcome: .failure(.pairingCodeRejected))
        let model = Self.model(repository: repository, pairing: pairing, credentials: credentials)

        await model.pair(with: sighting, code: "000000", fingerprint: Self.fingerprint())

        #expect(model.failure == LocalisError.pairingCodeRejected.userMessage)
        let hosts = try await repository.hosts()
        #expect(hosts.count == 1)
        let stored = try #require(hosts.first)
        #expect(stored.id == already.id)
        #expect(stored.pairingState == .paired)
        // The pin the user could still connect with is untouched.
        #expect(credentials.pins[already.id] == Self.pin())
    }

    // MARK: - Three failures, three sentences

    @Test("a rejected code, a dead session and a changed certificate say three different things")
    func failuresAreNotCollapsed() async throws {
        // They demand three unrelated actions — retype the digits, start pairing
        // again on the Mac, and stop. Any two sharing a sentence sends at least
        // one user to do something guaranteed not to work, and the wording that
        // would swallow all three ("Pairing failed. Try again.") reads perfectly
        // fine in review.
        let errors: [LocalisError] = [.pairingCodeRejected, .pairingSessionExpired, .certificatePinMismatch]

        var seen: [String] = []
        for error in errors {
            let credentials = SpyCredentials()
            let model = Self.model(
                repository: try Self.repository(),
                pairing: FakePairing(credentials: credentials, outcome: .failure(error)),
                credentials: credentials
            )

            await model.pair(with: try Self.sighting(), code: "000000", fingerprint: Self.fingerprint())

            // Each sentence is the one `LocalisError` already keeps for that
            // case, never a summary invented on this screen.
            #expect(model.failure == error.userMessage)
            seen.append(try #require(model.failure))
        }

        // The positive control for the assertion above. Comparing each failure
        // against `error.userMessage` would stay green if `userMessage` itself
        // ever returned one string for all three, because both sides of that
        // comparison are read from the same property.
        #expect(Set(seen).count == errors.count)
    }

    @Test("a refused certificate is not reported as a Mac that isn't answering")
    func certificateMismatchIsNamedNotAnOutage() async throws {
        // The worst sentence to get wrong here. Pairing is the moment the pin is
        // established, so a certificate that fails is either a machine the user
        // has not actually reached or one presenting a key that is not the one
        // on their screen. "Check it's running and on the same network" invites
        // a retry, and a retry that succeeds against the wrong certificate pins
        // the wrong certificate — permanently, with no override by design.
        let credentials = SpyCredentials()
        let model = Self.model(
            repository: try Self.repository(),
            pairing: FakePairing(credentials: credentials, outcome: .failure(.certificatePinMismatch)),
            credentials: credentials
        )

        await model.pair(with: try Self.sighting(), code: "418302", fingerprint: Self.fingerprint())

        let failure = try #require(model.failure)
        #expect(failure == LocalisError.certificatePinMismatch.userMessage)
        #expect(failure != LocalisError.unreachable().userMessage)
        #expect(model.pairedHost == nil)
        #expect(credentials.pins.isEmpty)
    }

    @Test("a machine on file presenting a different certificate is refused, not re-pinned")
    func aKnownMachinePresentingADifferentKeyIsRefused() async throws {
        // `HostRecognition` calls this `.untrusted`. Re-pinning here would
        // overwrite a good trust anchor with a stranger's, which is the exact
        // substitution pinning exists to deny (constitution V — no override).
        let repository = try Self.repository()
        let credentials = SpyCredentials()
        let sighting = try Self.sighting()
        let known = try await Self.recordPaired(
            sighting, pinnedTo: Self.pin(1), in: repository, credentials: credentials
        )

        let pairing = FakePairing(credentials: credentials)
        let model = Self.model(repository: repository, pairing: pairing, credentials: credentials)

        // A different fingerprint, for a machine we already have a pin for.
        await model.pair(with: sighting, code: "418302", fingerprint: Self.fingerprint(2))

        #expect(model.failure == LocalisError.certificatePinMismatch.userMessage)
        // Nothing was even attempted: the refusal happens before the request, so
        // no code is spent against a machine we would refuse anyway.
        #expect(pairing.calls.isEmpty)
        // The good pin, and the record, are untouched.
        #expect(credentials.pins[known.id] == Self.pin(1))
        let stored = try #require(await repository.hosts().first)
        #expect(stored.pairingState == .paired)
    }

    // MARK: - FR-031

    @Test("a machine that moved is recognised, not recorded twice")
    func relocationKeepsOneRecord() async throws {
        // **This is the test that catches the join.** Recognition matches on the
        // pinned certificate, and the store has no pin column — so a model
        // reading `repository.hosts()` directly sees every machine as unpinned,
        // answers `.unknown`, and writes a *second* record. Nothing fails while
        // that happens: pairing succeeds, the pill says Paired, and a duplicate
        // row appears beside the first with the machine's history stranded
        // behind whichever one the user stops tapping.
        let repository = try Self.repository()
        let credentials = SpyCredentials()
        let known = try await Self.recordPaired(
            try Self.sighting(at: "mac.local"),
            pinnedTo: Self.pin(),
            in: repository,
            credentials: credentials
        )

        let model = Self.model(
            repository: repository,
            pairing: FakePairing(credentials: credentials),
            credentials: credentials
        )

        // Same machine, same certificate, new address — a DHCP renewal, or a
        // switch to a Tailscale address.
        await model.pair(
            with: try Self.sighting(at: "100.64.0.7"),
            code: "418302",
            fingerprint: Self.fingerprint()
        )

        #expect(model.failure == nil)
        let hosts = try await repository.hosts()
        #expect(hosts.count == 1)
        let stored = try #require(hosts.first)
        #expect(stored.id == known.id)
        #expect(stored.endpoint == HostEndpoint(host: "100.64.0.7", port: 8443))
    }

    // MARK: - What pairing writes

    @Test("an older bridge that omits bridge_id does not erase the one we had")
    func omittedBridgeIDIsNotAWrite() throws {
        // `withBridgeID(nil)` is a real write that clears the field, and
        // `bridge_id` is optional by protocol (Amendment A §1.6). Applying the
        // response unconditionally would erase an id that Bonjour had already
        // supplied, and the next relocation would fall back to matching by pin
        // alone.
        let record = LocalisHost(adopting: try Self.sighting()).withBridgeID("bridge-abc")
        let paired = HostPairingModel.paired(
            record,
            with: PairedBridge(bridgeName: "", protocolVersion: 1, bridgeID: nil),
            pinning: Self.pin()
        )

        #expect(paired.bridgeID == "bridge-abc")
        // A nameless bridge keeps the name the record already had, rather than
        // being listed as an empty string.
        #expect(paired.displayName == record.displayName)
        #expect(paired.canConnect)
    }

    @Test("what the bridge says about itself is recorded when it says anything")
    func pairingRecordsWhatTheBridgeReported() throws {
        let record = LocalisHost(adopting: try Self.sighting())
        let paired = HostPairingModel.paired(
            record,
            with: PairedBridge(bridgeName: "Studio", protocolVersion: 2, bridgeID: "bridge-xyz"),
            pinning: Self.pin()
        )

        #expect(paired.displayName == "Studio")
        #expect(paired.bridgeID == "bridge-xyz")
        #expect(paired.protocolVersion == 2)
        #expect(paired.pairingState == .paired)
    }

    // MARK: - Input refused before anything is sent

    @Test("a code that is not six digits is refused without spending an attempt")
    func shortCodeIsRefusedLocally() async throws {
        // The bridge would answer 401, which reads "that pairing code isn't
        // right" — true, and it also spends one of the five attempts that
        // invalidate the session. Three typos would kill a code that was never
        // actually tried.
        let credentials = SpyCredentials()
        let pairing = FakePairing(credentials: credentials)
        let model = Self.model(
            repository: try Self.repository(), pairing: pairing, credentials: credentials
        )

        await model.pair(with: try Self.sighting(), code: "4183", fingerprint: Self.fingerprint())

        // **The property, not the wording.** This used to assert equality with
        // `LocalisError.invalidInput(field: "code").userMessage`, which renders
        // as "Please check the code field." — a raw field name interpolated into
        // user-facing copy, and unlocalized by design (`LocalisError.swift:160`
        // says callers localize at the UI boundary). The model now says its own
        // sentence, so that assertion pinned a string production had stopped
        // producing.
        //
        // Restating the new sentence here would be the same trap one copy-edit
        // later: a test that fails on rewording teaches people to paste the new
        // value without reading it, and that habit gets spent on the next red,
        // which will be a real one. What must hold is that the user is told
        // about *the code* and is not handed the internal field name.
        let failure = try #require(model.failure)
        #expect(failure.localizedCaseInsensitiveContains("code"))
        #expect(failure != LocalisError.invalidInput(field: "code").userMessage)
        #expect(pairing.calls.isEmpty)
    }

    @Test("a non-numeric code is refused rather than sent")
    func nonNumericCodeIsRefusedLocally() async throws {
        // Six characters, so a length check alone lets it through. Worth its own
        // case because the field is a number pad on the screen — which makes
        // this look impossible until a paste arrives.
        let credentials = SpyCredentials()
        let pairing = FakePairing(credentials: credentials)
        let model = Self.model(
            repository: try Self.repository(), pairing: pairing, credentials: credentials
        )

        await model.pair(with: try Self.sighting(), code: "41830a", fingerprint: Self.fingerprint())

        // Property, not wording — see the note in the test above.
        let failure = try #require(model.failure)
        #expect(failure.localizedCaseInsensitiveContains("code"))
        #expect(failure != LocalisError.invalidInput(field: "code").userMessage)
        #expect(pairing.calls.isEmpty)
    }

    @Test("a truncated fingerprint is an input error, not an accusation about the Mac")
    func truncatedFingerprintIsAnInputError() async throws {
        // A truncated paste is still valid base64, so it reaches the handshake
        // and is refused there — as `certificatePinMismatch`, whose wording says
        // this Mac's identity has changed. That accuses the machine of something
        // for what is a paste that lost its tail, and it is the one sentence in
        // this vocabulary a user must never learn to click past.
        let credentials = SpyCredentials()
        let pairing = FakePairing(credentials: credentials)
        let model = Self.model(
            repository: try Self.repository(), pairing: pairing, credentials: credentials
        )

        let truncated = String(Self.fingerprint().dropLast(8))
        await model.pair(with: try Self.sighting(), code: "418302", fingerprint: truncated)

        #expect(model.failure != LocalisError.invalidInput(field: "fingerprint").userMessage)
        // **The assertion this test exists for**, and it is the inequality
        // rather than the equality: whatever the wording becomes, it must not be
        // the one that says this Mac's identity has changed. That sentence is
        // the one a user must never learn to click past, and a paste that lost
        // its tail must not be what teaches them to.
        #expect(model.failure != LocalisError.certificatePinMismatch.userMessage)
        // Says something about the fingerprint, without pinning the sentence.
        let failure = try #require(model.failure)
        #expect(failure.localizedCaseInsensitiveContains("fingerprint"))
        #expect(pairing.calls.isEmpty)
    }

    @Test("a fingerprint that is not base64 at all is refused")
    func garbageFingerprintIsRefused() throws {
        #expect(throws: LocalisError.invalidInput(field: "fingerprint")) {
            try HostPairingModel.validatedFingerprint("not a fingerprint")
        }
    }

    @Test("a fingerprint split across lines by the terminal still pairs")
    func wrappedFingerprintIsAccepted() throws {
        // Whitespace is stripped throughout, not trimmed at the ends: the value
        // is read out of a terminal, and a wrap lands in the middle of it as
        // often as anywhere.
        let whole = Self.fingerprint()
        let wrapped = whole.prefix(20) + "\n  " + whole.dropFirst(20)

        #expect(try HostPairingModel.validatedFingerprint(String(wrapped)) == Self.pin())
    }

    // MARK: - Discovery

    @Test("the same machine advertising twice is one row, at its newest address")
    func repeatedSightingsCollapse() async throws {
        // `BridgeDiscovery.hosts()` is deliberately not deduplicated: a repeat
        // *is* the address change, and swallowing it would strand the host at an
        // endpoint that no longer answers. A list is the other side of that —
        // the same Mac offered five times is five chances to pick the wrong one.
        let first = try Self.sighting(at: "mac.local")
        let again = try Self.sighting(at: "mac.local")
        let other = try Self.sighting(at: "studio.local")

        let credentials = SpyCredentials()
        let model = Self.model(
            repository: try Self.repository(),
            pairing: FakePairing(credentials: credentials),
            credentials: credentials,
            sightings: [first, again, other]
        )

        model.startDiscovery()
        try await Self.settle { model.discovered.count == 2 }

        #expect(model.discovered.map(\.endpoint.host) == ["mac.local", "studio.local"])
    }

    @Test("leaving the screen stops the browse and forgets what was seen")
    func stoppingDiscoveryClearsTheList() async throws {
        // A sighting is a claim about right now. Keeping the list across visits
        // would offer a machine that has left the network, which fails as a
        // timeout some seconds later with nothing on screen explaining why the
        // row was ever there.
        let credentials = SpyCredentials()
        let model = Self.model(
            repository: try Self.repository(),
            pairing: FakePairing(credentials: credentials),
            credentials: credentials,
            sightings: [try Self.sighting()]
        )

        model.startDiscovery()
        try await Self.settle { model.discovered.count == 1 }

        model.stopDiscovery()
        #expect(model.discovered.isEmpty)
    }

    @Test("a typed address is offered without being stored")
    func manualEntryIsOfferedNotRecorded() async throws {
        // **Deliberately different from `HostListModel.addHost(typedAddress:)`,
        // which saves immediately.** A stored `.discovered` host has no pin, and
        // recognition matches on the pin — so writing a record here would mean
        // `pair` fails to recognise the row it had itself just written, and
        // creates a *second* record for the same machine.
        let repository = try Self.repository()
        let credentials = SpyCredentials()
        let model = Self.model(
            repository: repository,
            pairing: FakePairing(credentials: credentials),
            credentials: credentials
        )

        try model.addManualHost(address: "https://studio.local:9000")

        #expect(model.discovered.map(\.endpoint.displayText) == ["studio.local:9000"])
        #expect(try await repository.hosts().isEmpty)
    }

    @Test("a typed address that is not usable is refused")
    func manualEntryValidates() async throws {
        // Plaintext, deliberately: `EndpointValidator` is HTTPS-only, and a
        // free-text field is exactly where a plaintext fallback would reappear.
        let credentials = SpyCredentials()
        let model = Self.model(
            repository: try Self.repository(),
            pairing: FakePairing(credentials: credentials),
            credentials: credentials
        )

        #expect(throws: LocalisError.invalidInput(field: "endpoint")) {
            try model.addManualHost(address: "http://studio.local:9000")
        }
        #expect(model.discovered.isEmpty)
    }

    // MARK: - Identity

    @Test("a machine that moves keeps the row the user was looking at")
    func relocationKeepsTheSelectedRow() async throws {
        // **The bug this exists for was in the gap between two files.** The list
        // collapsed a relocated machine onto its existing row while the screen
        // keyed its rows — and its selection — on the endpoint alone. So a DHCP
        // renewal was one row here and a different row there: SwiftUI tore the
        // row down and rebuilt it, the checkmark went out, and the selection the
        // screen still held carried the *old* address. Tapping Pair then sent
        // the exchange to where the Mac used to be, which fails as a timeout
        // some seconds later against a machine that was on screen and reachable
        // the whole time.
        //
        // Asserted through `identity` because that is what the `ForEach` keys
        // on: an assertion about the endpoints would pass with the row identity
        // still broken, which is the state that shipped the bug.
        let credentials = SpyCredentials()
        let moved = try Self.sighting(at: "100.64.0.7")
        let model = Self.model(
            repository: try Self.repository(),
            pairing: FakePairing(credentials: credentials),
            credentials: credentials,
            sightings: [try Self.sighting(at: "mac.local"), moved]
        )

        // Two sightings of *different* machines by this rule — no bridge id is
        // available from the app target, so an address change is all the list
        // can see. This states what the manual path really does, which is the
        // path this screen adds.
        model.startDiscovery()
        try await Self.settle { model.discovered.count == 2 }

        // What the view holds after a tap: a value, not an index.
        let selected = try #require(model.discovered.first { $0.endpoint.host == "100.64.0.7" })
        let current = try #require(model.current(selected))
        #expect(current.identity == selected.identity)
        // The row identity is stable across a re-render, which is what keeps the
        // checkmark on the machine the user chose.
        #expect(model.discovered.map(\.identity).contains(selected.identity))
    }

    @Test("re-typing an address a machine already has does not add a second row")
    func manualEntryOfAKnownAddressSelectsTheExistingRow() async throws {
        // `addManualHost` merges rather than appends, so the screen cannot take
        // `discovered.last` as "the one just added" — with one row replaced and
        // nothing appended, `.last` is whichever unrelated machine happens to be
        // at the end, and the checkmark lands on the wrong Mac. The model
        // returning what it added is what closes that.
        let credentials = SpyCredentials()
        let model = Self.model(
            repository: try Self.repository(),
            pairing: FakePairing(credentials: credentials),
            credentials: credentials,
            sightings: [try Self.sighting(at: "mac.local"), try Self.sighting(at: "studio.local")]
        )

        model.startDiscovery()
        try await Self.settle { model.discovered.count == 2 }

        let added = try model.addManualHost(address: "https://mac.local:8443")

        #expect(model.discovered.count == 2)
        #expect(added.endpoint.host == "mac.local")
        // The value handed back is the row, not a stray parse of the text.
        #expect(model.discovered.map(\.identity).contains(added.identity))
        // And it is *not* the last row, which is exactly what made `.last` wrong.
        #expect(model.discovered.last?.identity != added.identity)
    }

    @Test("two sightings are the same machine in either order")
    func identityIsSymmetric() throws {
        // A `ForEach` key is an equivalence relation whether or not anyone
        // checks. The rule this replaced was not: it merged a sighting carrying
        // a bridge id onto an id-less row at the same address but not the
        // reverse, so whether the user saw one row or two depended on whether
        // they typed the address before or after Bonjour answered — an ordering
        // nobody controls and no assertion would have caught.
        let a = try Self.sighting(at: "mac.local")
        let b = try Self.sighting(at: "mac.local")
        let other = try Self.sighting(at: "studio.local")

        #expect(HostPairingModel.isSameMachine(a, as: b))
        #expect(HostPairingModel.isSameMachine(b, as: a))
        #expect(!HostPairingModel.isSameMachine(a, as: other))
        #expect(!HostPairingModel.isSameMachine(other, as: a))
        // Reflexive, and equal identities are what the `ForEach` compares.
        #expect(HostPairingModel.isSameMachine(a, as: a))
        #expect(a.identity == b.identity)
        #expect(a.identity != other.identity)
    }

    @Test("a bridge id and an address cannot be mistaken for each other")
    func identityIsNamespaced() throws {
        // Cheap to state, and the alternative is a collision nobody would ever
        // reproduce: a bridge whose `hid` happens to read like `host:port`
        // matching a machine actually at that address.
        let host = try Self.sighting(at: "mac.local", port: 8443)

        #expect(host.identity == "endpoint:mac.local:8443")
        #expect(!host.identity.hasPrefix("hid:"))
    }

    // MARK: - Device identity

    @Test("this device keeps one id across pairings")
    func deviceIDIsStable() throws {
        // The Mac's token store is keyed by this. An id that changed per
        // pairing would leave a live token behind for a device that no longer
        // exists, every time — and nothing on either side would report it.
        //
        // A private suite name rather than `.standard`: a test that wrote into
        // the developer's own defaults would pass once and then pass for the
        // wrong reason forever after.
        let suite = "HostPairingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DeviceIdentity.persistedID(in: defaults)
        let second = DeviceIdentity.persistedID(in: defaults)

        #expect(first == second)
        // Read back off the store rather than only compared in memory, so a
        // version that returned a stable value without persisting it fails.
        let raw = try #require(defaults.string(forKey: DeviceIdentity.defaultsKey))
        #expect(UUID(uuidString: raw) == first)
    }

    @Test("a fresh install mints its own id rather than inheriting one")
    func deviceIDIsPerInstall() throws {
        let suiteA = "HostPairingTests.\(UUID().uuidString)"
        let suiteB = "HostPairingTests.\(UUID().uuidString)"
        let a = try #require(UserDefaults(suiteName: suiteA))
        let b = try #require(UserDefaults(suiteName: suiteB))
        defer {
            a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }

        // The positive control for the test above: if `persistedID` returned a
        // constant, "same id twice" would pass and this would fail.
        #expect(DeviceIdentity.persistedID(in: a) != DeviceIdentity.persistedID(in: b))
    }

    /// Waits for a condition the browse task has to reach.
    ///
    /// Polling rather than a fixed sleep: a sleep long enough to be reliable is
    /// long enough to be felt in every run, and one short enough not to be felt
    /// fails on a loaded CI machine. Records an issue rather than returning
    /// quietly, so a condition that never comes true is a named failure instead
    /// of a passing assertion against a half-filled list.
    private static func settle(until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the discovery stream never reached the expected state")
    }
}
