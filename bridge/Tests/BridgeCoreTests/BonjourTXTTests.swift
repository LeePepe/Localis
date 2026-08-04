import Foundation
import Testing

@testable import BridgeCore

/// The Bonjour TXT record this bridge advertises (contract §0).
///
/// **This is the one place where a silent typo costs the whole discovery
/// path.** iOS reads three keys by name — `v`, `name`, `hid`. A bridge that
/// advertises `version=` instead of `v=` is still discoverable, still
/// connectable, and still shows up in the list; it just never matches a known
/// host and never reports its protocol. Nothing fails, nothing logs.
@Suite("BonjourTXT")
struct BonjourTXTTests {
    /// The key names, spelled out here on purpose.
    ///
    /// Written as literals rather than referencing the constants under test:
    /// comparing `TXTKey.version` to itself proves the code agrees with itself.
    /// These three strings are what the iOS `TXTKey` enum contains, and if
    /// someone renames one of them this test is where it hurts.
    @Test("the record carries exactly v, name and hid")
    func keysAreContractSpelled() {
        let record = BonjourTXT.record(version: 1, name: "Mac", instanceID: "abc123")

        #expect(Set(record.keys) == ["v", "name", "hid"])
    }

    @Test("values are what was passed in")
    func valuesRoundTrip() {
        let record = BonjourTXT.record(version: 1, name: "Tian's MacBook Pro", instanceID: "abc123")

        #expect(record["v"] == "1")
        #expect(record["name"] == "Tian's MacBook Pro")
        #expect(record["hid"] == "abc123")
    }

    /// The protocol version is the one the HTTP layer reports.
    ///
    /// Two sources for one number is how a bridge ends up advertising `v=1`
    /// over Bonjour while answering `x-localis-protocol: 2` — and the client
    /// decides compatibility from the second after trusting the first.
    @Test("the advertised version is the protocol version the server reports")
    func versionAgreesWithTheHTTPHeader() {
        let record = BonjourTXT.record(version: BridgeProtocol.version, name: "Mac", instanceID: "x")

        #expect(record["v"] == String(BridgeProtocol.version))
    }

    // MARK: - Wire encoding

    /// Each entry is length-prefixed. Getting this wrong yields a record that
    /// parses as garbage rather than one that fails to parse.
    @Test("each entry is encoded as a length-prefixed key=value")
    func encodesLengthPrefixed() throws {
        let bytes = BonjourTXT.encode(["v": "1"])

        #expect(bytes == [3] + Array("v=1".utf8))
    }

    @Test("every entry in a multi-key record is present and length-prefixed")
    func encodesEveryEntry() throws {
        let record = ["v": "1", "name": "Mac", "hid": "abc"]
        let bytes = BonjourTXT.encode(record)

        // Walked rather than pattern-matched: the dictionary has no order, so
        // the check has to be "every entry appears, correctly framed", not
        // "the bytes equal this literal".
        var decoded: [String: String] = [:]
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            let entry = String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self)
            let parts = entry.split(separator: "=", maxSplits: 1)
            decoded[String(parts[0])] = String(parts[1])
            index += 1 + length
        }

        #expect(decoded == record)
    }

    /// A single entry cannot exceed 255 bytes — the length prefix is one byte.
    ///
    /// The failure this rules out is silent and total: a truncated length byte
    /// makes every *subsequent* entry unparseable too, so one long machine name
    /// would take `hid` down with it.
    @Test("an over-long entry is dropped rather than truncated into garbage")
    func dropsOverLongEntry() {
        let huge = String(repeating: "x", count: 300)
        let bytes = BonjourTXT.encode(["name": huge, "v": "1"])

        var index = 0
        var seen: Set<String> = []
        while index < bytes.count {
            let length = Int(bytes[index])
            #expect(length <= 255)
            let entry = String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self)
            seen.insert(String(entry.split(separator: "=", maxSplits: 1)[0]))
            index += 1 + length
        }

        #expect(seen == ["v"], "the short entries must survive a neighbour being too long")
    }

    // MARK: - Service name

    /// Bonjour instance names are capped at 63 *bytes*, not characters.
    @Test("a long name is shortened to fit")
    func shortensLongName() {
        let name = BonjourTXT.serviceName(for: String(repeating: "M", count: 200))

        #expect(name.utf8.count <= 63)
        #expect(!name.isEmpty)
    }

    /// **The trap.** Truncating at a byte offset splits multi-byte characters.
    ///
    /// A Mac called "李的 MacBook Pro 工作机" is ordinary, and cutting its name
    /// at byte 63 lands mid-character. The result is not valid UTF-8, and
    /// `mDNSResponder` rejects the registration outright — so the bridge
    /// advertises nothing at all, on exactly the machines whose owners do not
    /// write in ASCII.
    @Test("shortening never splits a multi-byte character", arguments: [
        "李的 MacBook Pro 工作机器名字特别长特别长特别长特别长特别长特别长特别长",
        "Тианов макбук про очень длинное имя машины для теста границы",
        "🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️🖥️",
    ])
    func shorteningKeepsValidUTF8(original: String) {
        let name = BonjourTXT.serviceName(for: original)

        #expect(name.utf8.count <= 63)
        // Round-tripping through UTF-8 is the check: a split character would
        // not survive it intact.
        let reparsed = String(decoding: Array(name.utf8), as: UTF8.self)
        #expect(reparsed == name, "shortening produced invalid UTF-8: \(Array(name.utf8))")
        #expect(!name.isEmpty)
    }

    /// A short name is left exactly as it is.
    @Test("a name that already fits is untouched")
    func shortNameUnchanged() {
        #expect(BonjourTXT.serviceName(for: "Tian's MacBook Pro") == "Tian's MacBook Pro")
    }

    /// An empty or blank machine name still has to produce something.
    ///
    /// `mDNSResponder` will happily register an empty instance name and then the
    /// user sees a blank row they cannot identify.
    @Test("a blank name falls back to something identifiable", arguments: ["", "   ", "\n"])
    func blankNameFallsBack(original: String) {
        let name = BonjourTXT.serviceName(for: original)

        #expect(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
