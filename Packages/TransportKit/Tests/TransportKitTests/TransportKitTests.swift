import Foundation
import Testing

@testable import TransportKit

import LocalisModels

@Suite("SSEParser")
struct SSEParserTests {
    @Test("parses a single complete frame")
    func parsesSingleFrame() {
        let (frames, _) = SSEParser().parse("event: message\ndata: hello\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "message")
        #expect(frames[0].data == "hello")
    }

    @Test("buffers a partial frame until the terminator arrives")
    func buffersPartialFrame() {
        let (first, parser) = SSEParser().parse("data: par")
        #expect(first.isEmpty)

        let (second, _) = parser.parse("tial\n\n")
        #expect(second.count == 1)
        #expect(second[0].data == "partial")
    }

    @Test("splits multiple frames in one chunk")
    func parsesMultipleFrames() {
        let (frames, _) = SSEParser().parse("data: one\n\ndata: two\n\n")

        #expect(frames.map(\.data) == ["one", "two"])
    }

    @Test("joins repeated data fields with newlines")
    func joinsMultilineData() {
        let (frames, _) = SSEParser().parse("data: line1\ndata: line2\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].data == "line1\nline2")
    }

    @Test("ignores comment keep-alives")
    func ignoresKeepAlives() {
        let (frames, _) = SSEParser().parse(": keep-alive\n\ndata: real\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].data == "real")
    }

    @Test("parsing does not mutate the original parser")
    func parserIsImmutable() {
        let parser = SSEParser()
        _ = parser.parse("data: x")

        #expect(parser.buffer.isEmpty)
    }
}

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
