import Foundation
import LocalisModels

/// Validation for user-entered agent endpoints.
///
/// This is a trust boundary: the endpoint is typed by hand and drives every
/// outbound request, so it is validated here once rather than at each call
/// site. Failures come back as `LocalisError.invalidInput` with the field name.
public enum EndpointValidator {
    /// Schemes Localis will talk to — **HTTPS only**.
    ///
    /// Plaintext HTTP has no fallback path, deliberately, even on the LAN
    /// (constitution principle V). Conversations carry source code and
    /// filesystem paths; "it's only my home network" is not a threat model.
    /// Failing to connect is the correct outcome, not a downgrade.
    ///
    /// Self-signed certificates are supported instead, pinned by SPKI SHA-256
    /// at pairing time — which is what makes HTTPS practical for a LAN agent
    /// without a public CA.
    public static let allowedSchemes: Set<String> = ["https"]

    /// Parses and normalizes a user-entered endpoint string.
    ///
    /// - Throws: `LocalisError.invalidInput(field:)` when the text is empty,
    ///   unparseable, missing a host, or uses a scheme we don't speak.
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalisError.invalidInput(field: "endpoint")
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            throw LocalisError.invalidInput(field: "endpoint")
        }
        guard allowedSchemes.contains(scheme) else {
            throw LocalisError.invalidInput(field: "endpoint")
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw LocalisError.invalidInput(field: "endpoint")
        }
        guard let url = components.url else {
            throw LocalisError.invalidInput(field: "endpoint")
        }
        return url
    }
}
