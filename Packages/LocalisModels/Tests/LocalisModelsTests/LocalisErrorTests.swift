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
        .unreachable, .connectionLost, .malformedResponse, .unauthorized,
        .invalidInput(field: "endpoint"), .cancelled,
        .tokenRevoked, .unknownBackend, .sessionBusy,
        .backendUnavailable(reason: nil), .backendUnavailable(reason: "not_logged_in"),
        .protocolUpgradeRequired(side: .app), .protocolUpgradeRequired(side: .bridge),
        .turnExpired, .unknownTurn, .turnNotYours,
        .certificatePinMismatch, .truncated
    ]

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
        #expect(LocalisError.unreachable.isRetryable)

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
}
