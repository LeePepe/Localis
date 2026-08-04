import Foundation

/// What the operating system said when a connection failed.
///
/// **Why this exists.** Everything below the transport — a refused certificate,
/// a name that does not resolve, a route that is simply dead — arrives as an
/// `NSError` and gets mapped to one `LocalisError` category. That mapping is
/// right for the user: all three mean "this did not go through", and the four
/// sentences `userMessage` can say are the four actions worth suggesting. It is
/// useless for whoever has to fix it. `NSURLErrorDomain -1202` means the pinned
/// certificate was rejected, which is a local trust problem; `-1004` means
/// nothing answered, which is the network or the address. Opposite fixes, and
/// after the collapse they are the same value.
///
/// Task #32 was diagnosed from the wrong end for several rounds because of
/// exactly this: every request failing with a pin mismatch reported as
/// "unreachable", and unreachable sends you to check the network — the one
/// thing that was fine.
///
/// **What may be in here, and why the line is where it is.** `domain` is a
/// Foundation constant name (`NSURLErrorDomain`, `NSPOSIXErrorDomain`) and
/// `code` is a number. Both are produced by the OS on *this* device.
///
/// The rule is not "these look harmless" — it is that **neither is free text
/// from the other end**. The bridge's own `error.message` may hold an absolute
/// path (contract §6, constitution I) and is never carried, and neither are the
/// token, the host name, or certificate bytes. `NSError.userInfo` is dropped
/// wholesale for the same reason: it routinely carries
/// `NSURLErrorFailingURLStringErrorKey`, whose URL contains the user's machine
/// name.
///
/// **Not user-facing.** `LocalisError.userMessage` does not read this, and
/// should not start: a number no user can act on, appended to a sentence they
/// can, makes the sentence worse. Keeping the boundary structural — the field
/// is simply not consulted — rather than by convention is deliberate; a
/// convention holds only until someone appends it "just for this one screen".
public struct TransportDiagnostic: Codable, Hashable, Sendable {
    /// The `NSError` domain, e.g. `NSURLErrorDomain`.
    public let domain: String
    /// The `NSError` code, e.g. `-1202` (certificate rejected).
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    /// Reads the identity off an `NSError`, and nothing else.
    ///
    /// Takes the two fields rather than storing the error: an initialiser that
    /// held the `NSError` would keep `userInfo` reachable, and the next person
    /// to need "just a bit more context" would find it already there.
    public init(_ error: any Error) {
        let ns = error as NSError
        self.domain = ns.domain
        self.code = ns.code
    }
}
