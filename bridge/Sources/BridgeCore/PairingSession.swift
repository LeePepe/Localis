import Crypto
import Foundation

/// The out-of-band pairing handshake (contract §1).
///
/// A six-digit code shown on the Mac, typed into the phone. That code is the
/// only thing standing between anyone on the LAN and a token that can run CLI
/// tools on this machine, so the properties below are not incidental:
///
/// - **Single use.** A code that still works after it has been used is a code
///   an observer can reuse.
/// - **Short-lived.** 120 seconds, after which the user starts again. A code
///   left on screen overnight is a code with all night to be guessed.
/// - **Five attempts, then dead.** Six digits is a million possibilities, which
///   sounds ample until you notice a LAN attacker can try them at wire speed.
///   The lockout is what turns "a million" into a real bound.
/// - **Compared in constant time.** A comparison that returns early on the
///   first wrong digit leaks how many digits were right, and six digits guessed
///   one at a time is sixty attempts, not a million.
///
/// The distinction between "wrong code" and "session dead" is carried out to
/// the client (401 vs 429) because the two demand opposite actions: retype
/// versus start over on the Mac. Collapsing them tells a user whose session is
/// dead to try again, advice guaranteed to fail.
public actor PairingSession {
    /// How long a code stays live.
    public static let lifetime: TimeInterval = 120

    /// Failures before the session is destroyed.
    public static let maximumAttempts = 5

    private let code: String
    private let expiresAt: Date
    private let bridgeName: String
    private let bridgeID: String

    private var failures = 0
    private var consumed = false

    /// A clock, so tests can reach expiry without waiting two minutes.
    private let now: @Sendable () -> Date

    public init(
        code: String,
        bridgeName: String,
        bridgeID: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.code = code
        self.bridgeName = bridgeName
        self.bridgeID = bridgeID
        self.now = now
        self.expiresAt = now().addingTimeInterval(Self.lifetime)
    }

    /// Generates a fresh six-digit code from the system CSPRNG.
    ///
    /// `SystemRandomNumberGenerator`, not `Int.random(in:)` with a seeded
    /// generator and not anything derived from the clock. A predictable code is
    /// no code at all, and the failure is silent — everything works, for
    /// everyone, including whoever predicted it.
    public static func generateCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt32.random(in: 0..<1_000_000, using: &generator)

        // Zero-padded: 42 must display and be typed as "000042", or a code
        // beginning with zeros becomes a code the user cannot enter.
        return String(format: "%06u", value)
    }

    /// What the pairing attempt produced.
    public enum Outcome: Sendable, Equatable {
        /// The code matched. Carries the token to return exactly once.
        case paired(token: String, bridgeName: String, bridgeID: String)
        /// Wrong code, session still live — 401. Retyping can work.
        case rejected
        /// Session dead, from expiry, exhausted attempts, or already used —
        /// 429. Retyping cannot work; the user has to start over on the Mac.
        case sessionExpired
    }

    /// Checks a submitted code and, on success, issues the token.
    public func submit(code submitted: String) -> Outcome {
        guard !consumed, failures < Self.maximumAttempts, now() < expiresAt else {
            // Every dead state answers identically. Distinguishing "expired"
            // from "too many attempts" would tell an attacker which of their
            // own actions ended the session.
            return .sessionExpired
        }

        guard Self.constantTimeEquals(submitted, code) else {
            failures += 1
            // The fifth failure is still a rejection to *this* caller — the
            // session is now dead, and the next attempt will say so. Answering
            // 429 here would confirm the attempt count on the attempt that
            // reached it.
            return .rejected
        }

        consumed = true
        return .paired(token: Self.generateToken(), bridgeName: bridgeName, bridgeID: bridgeID)
    }

    /// A bearer token with 256 bits of entropy.
    ///
    /// Long because it never expires and is typed by no one — there is no cost
    /// to length here, and a token that grants CLI execution on someone's Mac
    /// is not the place to economise.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }

        // URL-safe base64: the token travels in an `Authorization` header, and
        // `+` and `/` survive that fine — but they do not survive every proxy
        // and log tool between here and there.
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares two strings without returning early.
    ///
    /// The loop runs over every byte regardless of what it finds. An
    /// early-return comparison leaks, through timing, how far the match got —
    /// which turns guessing six digits from one-in-a-million into ten guesses
    /// per digit.
    ///
    /// Lengths are compared first, which does leak length. That is acceptable
    /// here and unavoidable: the code's length is a published constant.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = [UInt8](lhs.utf8)
        let right = [UInt8](rhs.utf8)

        guard left.count == right.count else { return false }

        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
