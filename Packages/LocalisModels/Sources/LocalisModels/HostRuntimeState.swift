import Foundation

/// Runtime state about a host, computed and **never persisted**.
///
/// Amendment C §4.2: reachability, latency and last-seen are observations, not
/// facts about the machine. Keeping them out of `Host` is what stops a stale
/// "unreachable" from being written to disk and read back as truth after the
/// network recovered. Aggregates like "2 of 3 reachable" are derived the same
/// way and equally unstored.
///
/// Deliberately **not** `Codable` — the type system enforces the rule.
public struct HostRuntimeState: Hashable, Sendable {
    public let reachability: HostReachability
    /// Round-trip time of the last successful probe, when one has succeeded.
    public let latencyMs: Int?
    /// When the host last answered. "6 minutes ago" and "3 days ago" are
    /// different situations for the user (Amendment C §4.2).
    public let lastSeenAt: Date?

    public init(
        reachability: HostReachability = .unknown,
        latencyMs: Int? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.reachability = reachability
        self.latencyMs = latencyMs
        self.lastSeenAt = lastSeenAt
    }

    public func withReachability(_ newReachability: HostReachability) -> HostRuntimeState {
        HostRuntimeState(reachability: newReachability, latencyMs: latencyMs, lastSeenAt: lastSeenAt)
    }

    /// Records a successful probe.
    public func seen(at timestamp: Date, latencyMs newLatency: Int?) -> HostRuntimeState {
        HostRuntimeState(reachability: .reachable, latencyMs: newLatency, lastSeenAt: timestamp)
    }
}

/// Whether a host is answering right now.
///
/// `unknown` is the honest starting value — before the first probe we have not
/// established that a host is down, and showing it as unreachable would be a
/// lie the user has to disprove.
public enum HostReachability: Hashable, Sendable {
    case reachable
    case unreachable(reason: HostUnreachableReason)
    case unknown
    /// No probe is possible at all: the pairing record says `.paired`, but this
    /// device holds no pin for the machine, so there is nothing to connect with.
    ///
    /// **Split out of `unknown` because silence is honest for only one of the
    /// two** (#51). Both were `unknown`, both rendered as no sentence, and on
    /// the card they were indistinguishable — but "the answer has not come back
    /// yet" resolves itself in a moment, and "there is no credential to ask
    /// with" never does. `team-lead` hit the second while accepting #48: a
    /// "Paired" pill with nothing under it, on a machine that could never
    /// answer.
    ///
    /// **Not a `HostUnreachableReason`, deliberately.** Every case of that enum
    /// is produced by a distinct transport error — `ProbeReachabilityTests`
    /// asserts exactly that — and this state is reached without any request
    /// being made at all. A fifth reason there would also run into the ruling
    /// recorded on `HostRevocation` (2026-08-04). This is the *absence* of a
    /// probe, not the result of one.
    ///
    /// **Recomputed, never persisted**, like everything else on this type: it
    /// is derived from the store plus the Keychain on every load, so restoring
    /// the pin clears it by itself. That is why the fix is here rather than a
    /// write that "reconciles" the pairing state — writing `.revoked` would
    /// silently unpair a machine the user never touched, and only a person
    /// could undo it.
    case unprobable
}

extension HostReachability {
    /// What to tell the user about a machine we hold no pin for.
    ///
    /// **A constant rather than a case-by-case `userMessage`** like
    /// `HostUnreachableReason`'s: there is exactly one way to reach
    /// `unprobable`, and an enum of one case carrying one sentence would be
    /// ceremony around a constant. If a second cause ever appears this becomes
    /// that enum, and the compiler will say so — the sentence would have to be
    /// chosen rather than looked up.
    ///
    /// **It claims nothing about the Mac**, because nothing was asked. Every
    /// existing sentence would misdescribe it: `unauthorized` says "this Mac no
    /// longer accepts this device" when it has neither accepted nor rejected
    /// anything, and `offline` sends the user to check a network that is
    /// probably fine. What is true is local — the credential is missing on
    /// *this device* — and the action is the one `HostAssembly.joined` already
    /// names for a restored device backup: pair it again.
    ///
    /// Lives in this module for the same reason `HostUnreachableReason`'s
    /// wording does: one vocabulary for "why this machine is unusable", derived
    /// locally, with nothing off the wire reaching a screen through it
    /// (constitution I).
    public static let missingCredentialMessage = String(
        localized: "This Mac's pairing is missing from this device. Pair again to restore it."
    )
}

extension HostReachability {
    /// The reachability a failed request establishes about its host (#40).
    ///
    /// Lives here rather than in `TransportKit` because both types do, and a
    /// transport-side mapping would be a second vocabulary that could disagree
    /// with `userMessage` about what a given failure means.
    ///
    /// **Not every `LocalisError` is a statement about the host.** Only the four
    /// below say something the user can act on; the rest are collapsed to
    /// `.offline` rather than being given cases of their own, because
    /// `.offline`'s advice — check the Mac is awake and on the network — is the
    /// only one that is harmless when the real cause was something else. The
    /// alternative, defaulting to the nearest specific case, tells a user to
    /// re-pair a machine whose certificate is fine.
    ///
    /// **Both 401 codes land on `.unauthorized`, which is a ruling and not an
    /// oversight** (`HostRevocation`, 2026-08-04). `LocalisError` keeps
    /// `tokenRevoked` and `unauthorized` apart because they call for opposite
    /// credential actions — one clears the Keychain, one does not. This enum
    /// answers a different question, *why is this host unusable right now*, and
    /// there both answers are "the credential no longer works, pair again". The
    /// action difference travels through `HostPairingState.revoked` instead of
    /// through a fifth reason, which would have to say what `.unauthorized`
    /// already says and would turn
    /// `HostUnreachableReasonWordingTests.reasonsAreNotInterchangeable` red.
    public init(failure: LocalisError) {
        switch failure {
        case .certificatePinMismatch:
            self = .unreachable(reason: .certificateRejected)
        case .unauthorized, .tokenRevoked:
            self = .unreachable(reason: .unauthorized)
        case .protocolUpgradeRequired:
            self = .unreachable(reason: .unsupportedProtocol)
        default:
            self = .unreachable(reason: .offline)
        }
    }
}

/// Why a host cannot be reached. Carried so the UI can say something specific
/// and actionable rather than a generic failure.
public enum HostUnreachableReason: String, CaseIterable, Sendable {
    /// No route: the machine is asleep, off, or we left its network.
    case offline
    /// Reached, but the certificate did not match the pin (constitution V).
    case certificateRejected
    /// Reached, but the token was rejected — re-pairing is required.
    case unauthorized
    /// The host speaks a protocol version this app does not support (FR-032).
    case unsupportedProtocol
}

extension HostUnreachableReason {
    /// Why this machine is not answering, in words the user can act on.
    ///
    /// **Production reaches this as of 2026-08-04 (#41/#48), which is what the
    /// note that stood here was waiting for.** The chain it described as missing
    /// two layers is now whole:
    ///
    ///     socket error → `TransportFailure` → `LocalisError` →
    ///     `HostReachability(failure:)` → `BridgeHostProbe.reachability(of:)` →
    ///     `HostListModel.refreshReachability` → `HostRowState.unreachableDetail`
    ///     → the host card.
    ///
    /// **What that note got right, and why the replacement is narrower.** Its
    /// point was that an injection-tested branch and a branch the live path
    /// drives look identical in a green report, which is true and was worth
    /// saying. Its trigger was not: "delete when a production caller constructs
    /// `.unreachable(reason:)`" was already satisfied inside this very file
    /// (`init(failure:)`, four lines up), so the condition could be met by code
    /// that reaches nobody. Constructing the value was never the thing in doubt.
    ///
    /// The thing in doubt is whether a *screen* gets it, and one command answers
    /// that:
    ///
    ///     grep -rn --include="*.swift" "HostRuntimeState(reachability:" \
    ///       Localis/Sources Packages/*/Sources
    ///
    /// A hit outside this file is a UI-layer caller building the value from
    /// something measured. Today there is exactly one — `HostListModel.swift`,
    /// where the probe's answers become rows. (`HostRowState`'s default is
    /// `HostRuntimeState()`, unlabelled, so it does not match and should not:
    /// a default is not a measurement. This comment matches itself, which is
    /// why the criterion is "a hit in another file", not a count.)
    ///
    /// If those hits ever fall back to this file alone, the display path has
    /// been unwired and every case below is once again reachable only from
    /// tests — restore a note like the one that used to stand here.
    ///
    /// (Quote the pattern when running it: unquoted, zsh expands `*.swift`
    /// itself, and the command fails without running, which looks exactly like
    /// zero hits.)
    ///
    /// **The reason this exists at all is that the four cases are four different
    /// user actions**, and a screen that renders them as one "unavailable" has
    /// discarded the only part worth carrying. Waiting fixes `offline` and fixes
    /// nothing else; `certificateRejected` must not read as something waiting or
    /// retrying could clear.
    ///
    /// Lives here rather than in the view layer for the same reason
    /// `LocalisError.userMessage` does: one vocabulary, derived locally from the
    /// case. Nothing off the wire reaches this text, so no absolute path from a
    /// host's own message can arrive on a screen through it (constitution I).
    ///
    /// Exhaustive with no `default`. A fifth reason must be given words here
    /// rather than inheriting whatever the previous case said — which is how a
    /// new failure ends up telling the user to re-pair a machine whose
    /// certificate is fine.
    public var userMessage: String {
        switch self {
        case .offline:
            // Says what is still true, because it usually is: the machine is
            // asleep or on another network, and nothing is wrong with pairing.
            return String(localized: "This Mac isn't answering. Check it's awake and on the same network.")
        case .certificateRejected:
            // Constitution V: no override, and it must not read as retryable.
            // Deliberately the same wording as
            // `LocalisError.certificatePinMismatch.userMessage` — the user is
            // in one situation and hitting it from two code paths should not
            // produce two different sentences about it.
            return String(localized: "This Mac's identity has changed. Pair again to confirm it's the same machine.")
        case .unauthorized:
            // Distinct from `certificateRejected` on purpose: the machine is
            // who it claims to be, this device's credential is what stopped
            // working. Both end in "pair again", but naming the wrong cause
            // sends the user to inspect the wrong thing when it does not help.
            return String(localized: "This Mac no longer accepts this device. Pair again to continue.")
        case .unsupportedProtocol:
            // Names an action on the *Mac*, not on this screen. FR-032's
            // mismatch is not something tapping here can resolve, and a message
            // that implies otherwise is an invitation to keep tapping.
            //
            // Which side is out of date is not known at this level —
            // `LocalisError.protocolUpgradeRequired` carries that and says so.
            // This value does not, so the text stays neutral rather than
            // guessing a direction and being wrong half the time.
            return String(localized: "This Mac's Bridge and Localis are different versions. Update the older one to continue.")
        }
    }
}
