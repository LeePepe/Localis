import Foundation

/// A capability a backend advertises in `/v1/models` (contract §2).
///
/// A `struct` wrapping the wire string rather than an `enum`, because the
/// contract requires both things at once:
///
/// > capabilities 枚举（客户端必须忽略未知值，**不得因此丢弃整项**）
///
/// A closed enum satisfies only the first half. Decoding a capability it has
/// never heard of fails, and the failure takes the whole backend down with it —
/// the user loses an agent from the picker because the host advertised one extra
/// word. That is exactly what the contract forbids, and it would also break
/// constitution IV's promise that a new capability needs no iOS release.
///
/// Named constants give back what the enum was for: `supports(.streaming)` is
/// checked at compile time, where `supports("steaming")` would have quietly
/// returned `false` forever.
public struct Capability: Hashable, Sendable, Codable, RawRepresentable {
    /// The wire spelling, preserved verbatim — including values this build does
    /// not recognise.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Streams tokens as they are produced.
    public static let streaming = Capability(rawValue: "streaming")
    /// Can invoke tools during a turn.
    public static let tools = Capability(rawValue: "tools")
    /// Accepts skill templates.
    public static let skills = Capability(rawValue: "skills")
    /// Operates on a workspace / project directory.
    public static let workspace = Capability(rawValue: "workspace")
    /// Requires outbound network access to answer.
    ///
    /// Note the wire spelling is snake_case. The conversion lives here so no
    /// caller has to remember which side of the boundary it is on.
    public static let requiresNetwork = Capability(rawValue: "requires_network")

    /// Every capability this build has a name for.
    public static let known: Set<Capability> = [
        .streaming, .tools, .skills, .workspace, .requiresNetwork
    ]

    /// Whether this build recognises the capability.
    ///
    /// Useful for deciding whether the UI can render an icon for it — never for
    /// deciding whether to keep it. An unknown capability is still a capability.
    public var isKnown: Bool { Self.known.contains(self) }

    // Encodes as a bare string rather than `{"rawValue": …}`, so a stored
    // backend list keeps matching what `/v1/models` sends.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Capability: CustomStringConvertible {
    public var description: String { rawValue }
}
