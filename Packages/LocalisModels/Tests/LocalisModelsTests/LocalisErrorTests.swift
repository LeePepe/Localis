import Foundation
import Testing

@testable import LocalisModels

/// Contract §6 — the error code table.
///
/// The contract is explicit that the bridge's `error.message` MUST NOT be shown
/// to the user (it may contain absolute paths — constitution I). So every code
/// the bridge can send has to have a local case here, or the text has nowhere to
/// come from but the wire.
@Suite("LocalisError contract coverage")
struct LocalisErrorContractTests {
    private static let allCases: [LocalisError] = [
        .unreachable(), .connectionLost, .malformedResponse, .unauthorized,
        .invalidInput(field: "endpoint"), .cancelled,
        .tokenRevoked, .unknownBackend, .sessionBusy,
        .backendUnavailable(reason: nil), .backendUnavailable(reason: "not_logged_in"),
        .protocolUpgradeRequired(side: .app), .protocolUpgradeRequired(side: .bridge),
        .turnExpired, .unknownTurn, .turnNotYours,
        .certificatePinMismatch, .truncated,
        .pairingCodeRejected, .pairingSessionExpired
    ]

    /// Every case is listed above.
    ///
    /// Four of the tests in this suite iterate `allCases`, so a case missing from
    /// that array is a case none of them check — and the suite stays green while
    /// covering less than it claims. The count is asserted here because there is
    /// no `CaseIterable` to lean on: `LocalisError` has associated values, and
    /// synthesising it would only enumerate one payload per case anyway.
    ///
    /// If this fails after you added a case, add it to `allCases` — do not raise
    /// the number. The number is the reminder, not the requirement.
    @Test("allCases really is all of them")
    func caseListIsComplete() {
        #expect(Self.allCases.count == 20)
    }

    @Test("every error carries a user-facing message")
    func allErrorsHaveUserMessages() {
        for error in Self.allCases {
            #expect(!error.userMessage.isEmpty)
        }
    }

    @Test("no user-facing message leaks a path, token, or raw payload")
    func userMessagesLeakNothing() {
        // FR-025 / constitution I. The standing risk is someone adding a case
        // that interpolates the bridge's own text; this catches the obvious
        // shapes of that mistake.
        for error in Self.allCases {
            let text = error.userMessage
            #expect(!text.contains("/"))
            #expect(!text.lowercased().contains("token"))
            #expect(!text.lowercased().contains("bearer"))
        }
    }

    @Test("a revoked token is distinct from a rejected one")
    func revokedTokenIsItsOwnCase() {
        // Both are 401, but only `token_revoked` requires clearing the stored
        // credential and re-pairing. Collapsing them would either drop a valid
        // token or leave a dead one on the device.
        #expect(LocalisError.tokenRevoked != LocalisError.unauthorized)
    }

    @Test("a rejected pairing code is distinct from an invalidated pairing session")
    func pairingRejectionIsDistinctFromExpiry() {
        // spec.md:62 (US1 scenario 3) writes both halves in one sentence —
        // "显示「配对码不对」…连续失败 5 次后该配对请求作废需重新发起" — but they
        // are two different things to do. A wrong code (401) means look at the
        // Mac's screen again; an invalidated session (429) means the code on
        // that screen is dead and the user has to start pairing over on the Mac.
        //
        // Collapsed into one case, the fifth wrong attempt still reads "wrong
        // code, try again", so the user retypes a code that can no longer work
        // — and every retry looks exactly like the four before it.
        #expect(LocalisError.pairingCodeRejected != LocalisError.pairingSessionExpired)
        #expect(
            LocalisError.pairingCodeRejected.userMessage
                != LocalisError.pairingSessionExpired.userMessage
        )
    }

    @Test("retrying the same code is offered only while the code can still work")
    func pairingRetryabilityMatchesTheCause() {
        // A wrong code is the one pairing failure where trying again is the
        // right move — the user misread a digit. Once the session is
        // invalidated, no number of attempts with any code will succeed until
        // pairing is restarted on the Mac, so offering retry sends the user
        // into a loop that cannot terminate.
        #expect(LocalisError.pairingCodeRejected.isRetryable)
        #expect(!LocalisError.pairingSessionExpired.isRetryable)
    }

    @Test("pairing failures are distinct from a rejected bearer token")
    func pairingFailuresAreNotUnauthorized() {
        // `unauthorized` is 401 `invalid_token` on an *already paired* host: the
        // bearer we hold was refused. The two pairing cases happen before any
        // token exists. They shared a case only because `LocalisError` had
        // nothing else, which put "your saved credential was refused" and "you
        // typed the wrong six digits" behind identical wording.
        #expect(LocalisError.pairingCodeRejected != LocalisError.unauthorized)
        #expect(LocalisError.pairingSessionExpired != LocalisError.unauthorized)
        #expect(LocalisError.pairingCodeRejected.userMessage != LocalisError.unauthorized.userMessage)
    }

    @Test("a protocol upgrade names which side to upgrade")
    func upgradeNamesTheSide() {
        // Contract §0: host newer than app → upgrade the app; host older →
        // upgrade the bridge. Telling the user to update the wrong end is worse
        // than saying nothing, so the side is decided at the transport boundary
        // and carried here as a conclusion, not as two numbers to re-compare.
        let upgradeApp = LocalisError.protocolUpgradeRequired(side: .app)
        let upgradeBridge = LocalisError.protocolUpgradeRequired(side: .bridge)

        #expect(upgradeApp != upgradeBridge)
        #expect(upgradeApp.userMessage != upgradeBridge.userMessage)
    }

    @Test("resume failures are retryable, and a pin mismatch never is")
    func retryabilityMatchesTheContract() {
        // §3.3: 404 unknown_turn and 410 turn_expired both mean "mark the
        // message interrupted and allow a retry".
        #expect(LocalisError.turnExpired.isRetryable)
        #expect(LocalisError.unknownTurn.isRetryable)
        #expect(LocalisError.truncated.isRetryable)
        #expect(LocalisError.unreachable().isRetryable)

        // Constitution V: a changed certificate has no "trust anyway" path, and
        // no retry either — retrying cannot make the certificate match.
        #expect(!LocalisError.certificatePinMismatch.isRetryable)
        #expect(!LocalisError.turnNotYours.isRetryable)
        #expect(!LocalisError.cancelled.isRetryable)
    }

    @Test("an unavailable backend can carry a machine-readable reason")
    func backendUnavailableCarriesShortCode() {
        // `unavailable_reason` from /v1/models is a short code (`not_logged_in`),
        // not the bridge's free text. It is kept so the UI can say "codex is not
        // logged in" instead of a generic failure.
        let withReason = LocalisError.backendUnavailable(reason: "not_logged_in")
        let without = LocalisError.backendUnavailable(reason: nil)

        #expect(withReason != without)
        #expect(!withReason.userMessage.isEmpty)
        #expect(!without.userMessage.isEmpty)
    }

    @Test("an unknown reason code still produces usable text")
    func unknownReasonFallsBackToGenericText() {
        // Open value set (constitution IV): a reason this build has never seen
        // must not produce an empty string or leak the raw code as the whole
        // message.
        let exotic = LocalisError.backendUnavailable(reason: "quota_exhausted_in_region")

        #expect(!exotic.userMessage.isEmpty)
        #expect(!exotic.userMessage.contains("quota_exhausted_in_region"))
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        // SessionStatus.error is persisted with the session, so every case has
        // to survive an encode/decode cycle.
        for error in Self.allCases {
            let data = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(LocalisError.self, from: data)
            #expect(decoded == error)
        }
    }

    @Test("a session persisted before the diagnostic existed still reads back")
    func preDiagnosticPayloadStillDecodes() throws {
        // `.unreachable` gained an associated value in #34, and it is persisted
        // — `SessionStatus.error` goes to disk with the session. A change to the
        // encoding would not fail any round-trip test (those encode and decode
        // with the same build); it would surface as conversations that stop
        // loading after an update, which is the user's data.
        //
        // The literal is the shape Swift synthesises for a case with no
        // associated value. Written out rather than generated, because a
        // fixture produced by the current build would encode whatever the
        // current build does — including a regression.
        let persistedBeforeDiagnostic = Data(#"{"unreachable":{}}"#.utf8)

        let decoded = try JSONDecoder().decode(LocalisError.self, from: persistedBeforeDiagnostic)

        #expect(decoded == .unreachable())
    }

    @Test("an unreachable with no cause encodes exactly as it used to")
    func absentDiagnosticIsOmittedNotNull() throws {
        // The other direction, and the reason the migration is a non-event: an
        // absent optional is *omitted*, not written as `null`. A build that
        // wrote `{"unreachable":{"diagnostic":null}}` would still satisfy the
        // test above — it decodes fine — while quietly making every newly
        // written session unreadable by the previous app version, which is what
        // a user who declines an update, or rolls one back, is running.
        let encoded = try JSONEncoder().encode(LocalisError.unreachable())

        #expect(String(data: encoded, encoding: .utf8) == #"{"unreachable":{}}"#)
    }

    @Test("the cause survives the round trip when there is one")
    func diagnosticRoundTrips() throws {
        // Otherwise the field would be write-only: correct in memory, gone by
        // the time anyone reads the session back to work out what happened —
        // which is the moment it exists for.
        let error = LocalisError.unreachable(
            diagnostic: TransportDiagnostic(domain: NSURLErrorDomain, code: -1202)
        )

        let decoded = try JSONDecoder().decode(
            LocalisError.self, from: try JSONEncoder().encode(error)
        )

        #expect(decoded == error)
        guard case .unreachable(let diagnostic) = decoded else {
            Issue.record("decoded into a different case")
            return
        }
        #expect(diagnostic?.code == -1202)
    }
}
