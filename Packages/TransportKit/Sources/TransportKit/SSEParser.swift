import Foundation

/// Incremental parser for `text/event-stream` (SSE) payloads.
///
/// Pure and synchronous so it can be unit-tested without a live socket: feed it
/// raw bytes as they arrive off the wire, get back whole frames. Bytes that do
/// not yet form a complete frame are buffered until the rest arrives.
///
/// **The buffer holds bytes, not text.** Decoding each network chunk to
/// `String` before framing corrupts any multi-byte character the network
/// happened to cut in half — the user sees a replacement character in the
/// middle of a word and no retry fixes it, because the damage happened before
/// parsing. UTF-8 decoding therefore happens once per frame, after framing.
///
/// The parser is a value type: `parse` returns the frames *and* the next parser
/// state rather than mutating in place, so a test can replay any chunk
/// boundary, including a split mid-character.
public struct SSEParser: Equatable, Sendable {
    /// Default cap on a single unterminated frame.
    ///
    /// A bridge that never sends a blank line would otherwise grow the buffer
    /// until the app is killed. 8 MiB is far above any legitimate frame — a
    /// chunk carries a token or two — and far below a memory emergency.
    public static let defaultBufferLimit = 8 * 1024 * 1024

    /// Bytes received so far that have not yet completed a frame.
    private let buffer: [UInt8]
    /// Cap on `buffer` before the stream is considered malformed.
    private let limit: Int
    /// Whether the stream is still at its very first byte, for BOM handling.
    private let isAtStart: Bool

    /// Whether an unterminated frame has exceeded `limit`.
    ///
    /// The caller turns this into a typed failure; the parser does not throw,
    /// so framing stays a pure function.
    public let hasOverflowed: Bool

    /// Whether anything is buffered — nothing arrived, or the last chunk ended
    /// exactly on a frame boundary.
    public var isEmpty: Bool { buffer.isEmpty }

    public init(limit: Int = SSEParser.defaultBufferLimit) {
        self.init(buffer: [], limit: limit, isAtStart: true, hasOverflowed: false)
    }

    private init(buffer: [UInt8], limit: Int, isAtStart: Bool, hasOverflowed: Bool) {
        self.buffer = buffer
        self.limit = limit
        self.isAtStart = isAtStart
        self.hasOverflowed = hasOverflowed
    }

    /// One parsed SSE frame.
    public struct Frame: Equatable, Sendable {
        /// The `event:` field, if the server sent one. `nil` for the unnamed
        /// frames that carry standard OpenAI chunks.
        public let event: String?
        /// The concatenated `data:` field(s), joined by newlines.
        public let data: String

        public init(event: String?, data: String) {
            self.event = event
            self.data = data
        }
    }

    /// Feeds `chunk` into the parser.
    ///
    /// - Returns: the frames completed by this chunk, and the parser state to
    ///   use for the next chunk.
    public func parse(bytes chunk: [UInt8]) -> (frames: [Frame], next: SSEParser) {
        guard !hasOverflowed else { return ([], self) }

        var working = buffer + chunk
        var atStart = isAtStart

        // A UTF-8 BOM may lead the stream; it is not part of any field.
        if atStart, working.count >= 3, working[0] == 0xEF, working[1] == 0xBB, working[2] == 0xBF {
            working.removeFirst(3)
        }
        if !working.isEmpty { atStart = false }

        var frames: [Frame] = []
        var lines: [[UInt8]] = []
        var lineStart = working.startIndex
        var index = working.startIndex
        /// Index just past the last byte consumed into a completed frame.
        var consumed = working.startIndex

        while index < working.endIndex {
            let byte = working[index]
            guard byte == Self.lineFeed || byte == Self.carriageReturn else {
                index += 1
                continue
            }

            let line = Array(working[lineStart..<index])
            var next = index + 1

            if byte == Self.carriageReturn {
                // A CR at the very end of the buffer may be the first half of a
                // CRLF still in flight. Treating it as a terminator now would
                // emit a phantom blank line and close the frame early, so stop
                // and wait for the next chunk.
                guard next < working.endIndex else { break }
                if working[next] == Self.lineFeed { next += 1 }
            }

            if line.isEmpty {
                // A blank line dispatches the frame. Field lines with no data
                // are not dispatchable, so they yield nothing.
                if let frame = Self.frame(from: lines) {
                    frames.append(frame)
                }
                lines.removeAll(keepingCapacity: true)
                consumed = next
            } else {
                lines.append(line)
            }

            lineStart = next
            index = next
        }

        let remainder = Array(working[consumed...])
        guard remainder.count <= limit else {
            return (frames, SSEParser(buffer: [], limit: limit, isAtStart: false, hasOverflowed: true))
        }
        return (frames, SSEParser(buffer: remainder, limit: limit, isAtStart: atStart, hasOverflowed: false))
    }

    /// Convenience overload for tests and fixtures that hold text.
    ///
    /// Real network chunks arrive as bytes and must use `parse(bytes:)` — a
    /// `String` has already lost any character the wire cut in half.
    public func parse(_ chunk: String) -> (frames: [Frame], next: SSEParser) {
        parse(bytes: Array(chunk.utf8))
    }

    /// Flushes the buffer at end of stream.
    ///
    /// One case survives to here: a trailing `CR` is ambiguous mid-stream —
    /// it may be the first half of a CRLF still in flight — so `parse` holds
    /// it rather than risk closing a frame early. Once the connection is done,
    /// no LF is coming and the CR is a terminator.
    ///
    /// A frame with no blank line after it is **discarded**, per the SSE spec.
    /// The bytes may be the front half of a chunk the bridge never finished
    /// sending; emitting a half-frame would hand the mapper a truncated JSON
    /// payload and turn a clean disconnect into a parse error.
    public func finish() -> [Frame] {
        guard !hasOverflowed, !buffer.isEmpty else { return [] }
        // A single trailing CR terminates the last line; append the LF that
        // the connection ended before sending.
        guard buffer.last == Self.carriageReturn else { return [] }

        let (frames, _) = parse(bytes: [Self.lineFeed])
        return frames
    }

    // MARK: - Field parsing

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20

    /// Assembles one frame from the field lines preceding a blank line.
    ///
    /// Returns nil when no `data:` field was present — comment-only keep-alives
    /// and bare `event:` lines are not dispatchable per the SSE spec, and must
    /// not surface as frames.
    private static func frame(from lines: [[UInt8]]) -> Frame? {
        var event: String?
        var dataLines: [String] = []

        for line in lines {
            // `:` in column 0 marks a comment / keep-alive.
            guard line.first != colon else { continue }

            let (field, value) = splitField(line)
            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            // `id` and `retry` belong to the SSE reconnection mechanism, which
            // the bridge protocol replaces with its own `seq` cursor
            // (Amendment C). Unknown fields are ignored per the SSE spec.
            default: continue
            }
        }

        guard !dataLines.isEmpty else { return nil }
        return Frame(event: event, data: dataLines.joined(separator: "\n"))
    }

    /// Splits `field: value`, tolerating a missing colon and one optional space.
    private static func splitField(_ line: [UInt8]) -> (field: String, value: String) {
        guard let colonIndex = line.firstIndex(of: colon) else {
            // Per the SSE spec a line with no colon is a field name with an
            // empty value.
            return (decode(line), "")
        }
        var valueStart = colonIndex + 1
        // Exactly one optional space after the colon is part of the framing.
        if valueStart < line.endIndex, line[valueStart] == space { valueStart += 1 }

        return (decode(Array(line[..<colonIndex])), decode(Array(line[valueStart...])))
    }

    /// Decoding is lossy on purpose: one corrupt byte must not end a turn that
    /// is otherwise fine.
    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
