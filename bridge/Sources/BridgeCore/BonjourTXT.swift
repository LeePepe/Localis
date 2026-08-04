import Foundation

/// The Bonjour TXT record and service name this bridge advertises (contract §0).
///
/// Separated from the registration itself so the parts that can be wrong
/// silently — key spelling, length limits, UTF-8 boundaries — are testable
/// without a multicast network. Registration needs `mDNSResponder`; this does
/// not.
public enum BonjourTXT {
    /// The record iOS reads: `v`, `name`, `hid` (contract §0).
    ///
    /// All three are keys the client looks up by name. A misspelling here does
    /// not fail — the bridge stays discoverable and connectable, it just never
    /// matches a known host and never reports a version. That is why the key
    /// names are asserted against literals in the tests rather than against
    /// these constants.
    public static func record(version: Int, name: String, instanceID: String) -> [String: String] {
        [Key.version: String(version), Key.name: name, Key.instanceID: instanceID]
    }

    enum Key {
        static let version = "v"
        static let name = "name"
        static let instanceID = "hid"
    }

    // MARK: - Wire encoding

    /// Encodes a record as DNS-SD TXT bytes: each entry a one-byte length
    /// followed by `key=value`.
    ///
    /// **An entry that cannot be framed is dropped, not truncated.** The length
    /// prefix is a single byte, so a 300-byte entry has no valid encoding; a
    /// truncated one would desynchronise the reader and take every *subsequent*
    /// entry down with it. Dropping costs one key — and since `name` is the
    /// likely offender and the client falls back to the service instance name,
    /// the visible result is a slightly different label rather than a machine
    /// that cannot be recognised.
    public static func encode(_ record: [String: String]) -> [UInt8] {
        // Sorted so the same record always produces the same bytes. Dictionary
        // order varies per process, and a record that re-encodes differently on
        // every launch is one whose diffs are unreadable.
        record.sorted { $0.key < $1.key }.reduce(into: [UInt8]()) { bytes, entry in
            let encoded = Array("\(entry.key)=\(entry.value)".utf8)
            guard encoded.count <= maximumEntryBytes else { return }
            bytes.append(UInt8(encoded.count))
            bytes.append(contentsOf: encoded)
        }
    }

    /// One byte of length means at most 255 bytes of entry.
    private static let maximumEntryBytes = 255

    // MARK: - Service name

    /// The Bonjour service instance name, within the 63-byte limit.
    ///
    /// **Shortened by character, not by byte.** Cutting at byte 63 splits
    /// multi-byte characters, and `mDNSResponder` rejects a registration whose
    /// instance name is not valid UTF-8 — so a Mac named in Chinese, Russian or
    /// emoji would advertise *nothing at all*, while an ASCII-named one works
    /// fine. That failure is invisible on the developer's machine and total on
    /// the user's.
    public static func serviceName(for machineName: String) -> String {
        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty instance name registers successfully and shows the user a
        // blank row they cannot identify — worse than a generic label.
        guard !trimmed.isEmpty else { return fallbackName }
        guard trimmed.utf8.count > maximumNameBytes else { return trimmed }

        var shortened = ""
        var used = 0
        for character in trimmed {
            let width = String(character).utf8.count
            guard used + width <= maximumNameBytes else { break }
            shortened.append(character)
            used += width
        }

        // Every character was individually too wide — impossible for UTF-8,
        // where no character exceeds four bytes, but the fallback is stated
        // rather than assumed: returning "" here would advertise a blank name.
        return shortened.isEmpty ? fallbackName : shortened
    }

    private static let maximumNameBytes = 63
    private static let fallbackName = "Localis Bridge"
}
