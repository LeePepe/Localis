import Foundation
import Testing

@testable import BridgeCore

/// The six-digit handshake.
///
/// Everything here is a security property, so the tests are written to fail
/// when a property is *removed* — not merely to demonstrate the happy path,
/// which stays green through a session that accepts any code at all.
@Suite("PairingSession — the six-digit handshake")
struct PairingSessionTests {
    @Test("the right code issues a token")
    func correctCodePairs() async {
        let session = PairingSession(code: "123456", bridgeName: "Mac", bridgeID: "b-1")

        guard case .paired(let token, let name, let id) = await session.submit(code: "123456") else {
            Issue.record("the correct code did not pair")
            return
        }

        #expect(!token.isEmpty)
        #expect(name == "Mac")
        #expect(id == "b-1")
    }

    /// **A code that works twice is a code an observer can reuse.**
    @Test("a code cannot be used a second time")
    func codeIsSingleUse() async {
        let session = PairingSession(code: "123456", bridgeName: "Mac", bridgeID: "b-1")

        _ = await session.submit(code: "123456")
        let second = await session.submit(code: "123456")

        #expect(second == .sessionExpired)
    }

    /// Wrong code, session still live: the user can retype. This is 401, and
    /// the client's own comment says the code on the Mac is still good.
    @Test("a wrong code is rejected without killing the session")
    func wrongCodeRejected() async {
        let session = PairingSession(code: "123456", bridgeName: "Mac", bridgeID: "b-1")

        let first = await session.submit(code: "000000")
        #expect(first == .rejected)

        // Still live: the right code works afterwards.
        guard case .paired = await session.submit(code: "123456") else {
            Issue.record("a single failure killed the session")
            return
        }
    }

    /// **Five failures, then dead.** Six digits is a million possibilities,
    /// which a LAN attacker exhausts quickly without this bound. The iOS side
    /// maps this to `pairingSessionExpired` and tells the user to start over on
    /// the Mac — advice that is only correct if the session really is dead.
    @Test("the session dies after five failures")
    func lockoutAfterFiveFailures() async {
        let session = PairingSession(code: "123456", bridgeName: "Mac", bridgeID: "b-1")

        // Five, written out. Looping over `maximumAttempts` would make this
        // test agree with whatever the constant says — including 50, which is
        // not a lockout. The bound is asserted separately, on purpose.
        #expect(PairingSession.maximumAttempts <= 5, "the lockout bound is too loose to be one")

        for _ in 0..<5 {
            let outcome = await session.submit(code: "000000")
            #expect(outcome == .rejected)
        }

        // Even the *correct* code now fails. A lockout the right code walks
        // through is not a lockout — an attacker who guesses on attempt six
        // would still be in.
        let afterLockout = await session.submit(code: "123456")
        #expect(afterLockout == .sessionExpired)
    }

    /// A code left on screen has 120 seconds, not all night.
    @Test("the session expires after its lifetime")
    func expiry() async {
        let clock = MutableClock()
        let session = PairingSession(
            code: "123456",
            bridgeName: "Mac",
            bridgeID: "b-1",
            now: clock.now
        )

        clock.advance(by: PairingSession.lifetime + 1)
        let outcome = await session.submit(code: "123456")

        #expect(outcome == .sessionExpired)
    }

    /// Just inside the window still works — otherwise the previous test would
    /// also pass against a session that expired instantly.
    @Test("the code still works just before expiry")
    func stillLiveBeforeExpiry() async {
        let clock = MutableClock()
        let session = PairingSession(
            code: "123456",
            bridgeName: "Mac",
            bridgeID: "b-1",
            now: clock.now
        )

        clock.advance(by: PairingSession.lifetime - 1)

        guard case .paired = await session.submit(code: "123456") else {
            Issue.record("the code expired early")
            return
        }
    }

    /// Codes must be six digits including leading zeros — `42` has to be
    /// `000042`, or a code the user cannot type is displayed on the Mac.
    @Test("generated codes are always six digits")
    func codeShape() {
        for _ in 0..<500 {
            let code = PairingSession.generateCode()
            #expect(code.count == 6)

            // ASCII digits specifically. `Character.isNumber` is true for
            // "٣" and "½" too, and a code the user cannot type on a numeric
            // keypad is a code that does not work.
            let allDigits = code.allSatisfy { $0.isASCII && $0.isNumber }
            #expect(allDigits, "not six typable digits: \(code)")
        }
    }

    /// A predictable code is no code at all, and the failure is silent —
    /// everything works, for everyone, including whoever predicted it.
    ///
    /// This cannot prove randomness, but it does catch a constant, a counter,
    /// or anything derived from a coarse clock.
    @Test("generated codes are not repeated")
    func codesVary() {
        let codes = Set((0..<500).map { _ in PairingSession.generateCode() })

        // 500 draws from a million: collisions are possible but a handful at
        // most (birthday bound ≈ 0.12 expected).
        #expect(codes.count > 490)
    }

    /// Tokens must not be guessable, and must survive a trip through an HTTP
    /// header and whatever logs it.
    @Test("tokens are long, unique, and URL-safe")
    func tokenShape() {
        let tokens = (0..<200).map { _ in PairingSession.generateToken() }

        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            #expect(token.count >= 40)

            let urlSafe = token.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
            #expect(urlSafe, "token is not URL-safe: \(token)")
        }
    }

    /// **The comparison must not return early.**
    ///
    /// Timing is too noisy to assert on directly in a unit test, so this checks
    /// the property that makes early return possible: the function's answer
    /// must not depend on *where* the difference is. A comparison correct only
    /// for a prefix is the shape that leaks.
    @Test("comparison depends on every position, not the first difference", arguments: [
        ("123456", "023456"),
        ("123456", "123450"),
        ("123456", "125456"),
        ("123456", "12345"),
        ("123456", "1234567"),
        ("123456", ""),
    ])
    func comparisonRejects(code: String, submitted: String) {
        #expect(!PairingSession.constantTimeEquals(code, submitted))
    }

    @Test("comparison accepts an exact match")
    func comparisonAccepts() {
        #expect(PairingSession.constantTimeEquals("123456", "123456"))
    }
}

/// A clock the test moves by hand.
///
/// Sleeping for two real minutes to observe expiry would make the suite unusable
/// — and a test too slow to run is a test that gets skipped.
private final class MutableClock: @unchecked Sendable {
    private var offset: TimeInterval = 0
    private let base = Date()
    private let lock = NSLock()

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return base.addingTimeInterval(offset)
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        offset += interval
    }
}
