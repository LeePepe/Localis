import Foundation
import Testing

@testable import TransportKit

import LocalisModels

@Suite("EndpointValidator")
struct EndpointValidatorTests {
    @Test("rejects plaintext HTTP even on the LAN")
    func rejectsLANHTTP() {
        // Constitution principle V: plaintext HTTP has no fallback path, and a
        // LAN address earns no exemption. Conversations carry source code and
        // filesystem paths. If this ever starts passing, someone has quietly
        // reintroduced a downgrade.
        #expect(throws: LocalisError.invalidInput(field: "endpoint")) {
            _ = try EndpointValidator.validate("http://192.168.1.20:8080")
        }
    }

    @Test("accepts https with an explicit port")
    func acceptsHTTPSWithPort() throws {
        let url = try EndpointValidator.validate("https://192.168.1.20:8080")

        #expect(url.host == "192.168.1.20")
        #expect(url.port == 8080)
    }

    @Test("accepts https and trims surrounding whitespace")
    func acceptsHTTPSAndTrims() throws {
        let url = try EndpointValidator.validate("  https://agent.local  ")

        #expect(url.scheme == "https")
        #expect(url.host == "agent.local")
    }

    @Test("rejects empty, hostless, and non-HTTPS endpoints", arguments: [
        "", "   ", "not a url", "ftp://agent.local", "file:///etc/passwd", "://missing",
        "http://agent.local", "HTTP://agent.local", "ws://agent.local", "wss://agent.local"
    ])
    func rejectsInvalidEndpoints(_ input: String) {
        #expect(throws: LocalisError.invalidInput(field: "endpoint")) {
            _ = try EndpointValidator.validate(input)
        }
    }
}
