import Foundation

/// Reassembles newline-delimited text from arbitrarily chunked reads.
///
/// A subprocess writes when its pipe buffer fills, not when a line ends. So a
/// single read can carry half a line, two lines and a fragment, or the middle
/// three bytes of a character. Every one of those is normal, and handling them
/// is what separates a decoder that works from one that fails under load with
/// no reproducible input.
///
/// Buffers **bytes, not text**, and decodes only at line boundaries. Decoding
/// each chunk as it arrives would corrupt any multi-byte character straddling a
/// read boundary — silently, into a replacement character.
///
/// A `struct` with `mutating` methods rather than a class: the accumulator is
/// owned by exactly one reader, and value semantics make that ownership a
/// property of the type instead of a convention.
public struct LineAccumulator: Sendable {
    private var buffer = Data()

    public init() {}

    /// Adds a chunk and returns whatever complete lines it completed.
    ///
    /// Returns an array because one chunk can complete zero, one, or many.
    public mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)

        var lines: [String] = []
        // `range(of:)` from the start each pass rather than a manual index:
        // `Data`'s indices are not guaranteed zero-based after slicing, and
        // hand-rolled offsets into a sliced `Data` are a classic source of
        // off-by-one crashes.
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]

            if let line = decode(lineBytes) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Yields a final unterminated line, if any.
    ///
    /// Call at EOF. The CLI's last line — for claude the `result` frame with
    /// usage and the turn's outcome — may arrive without a trailing newline,
    /// and without this it would be dropped exactly when it matters most.
    ///
    /// Idempotent: the buffer is cleared, so a caller that flushes defensively
    /// cannot process the same line twice.
    public mutating func flush() -> [String] {
        defer { buffer = Data() }

        guard let line = decode(buffer[...]) else { return [] }
        return [line]
    }

    // MARK: - Decoding

    /// Bytes to a usable line, or nil if there is nothing to pass on.
    ///
    /// Empty lines are framing rather than data; dropping them here saves every
    /// decoder downstream from repeating the same guard.
    private func decode(_ bytes: Data.SubSequence) -> String? {
        // A `\r\n` terminator would otherwise leave the `\r` inside the line,
        // where it survives JSON parsing and resurfaces as a stray character in
        // the user's transcript.
        var slice = bytes
        if slice.last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }

        guard !slice.isEmpty else { return nil }

        // Lossy rather than nil-on-failure: a byte sequence that is not valid
        // UTF-8 is a broken line, but discarding it entirely would take the
        // valid remainder of a `result` frame with it. Better a marred line the
        // JSON parser rejects loudly than a line that vanishes.
        return String(decoding: slice, as: UTF8.self)
    }
}
