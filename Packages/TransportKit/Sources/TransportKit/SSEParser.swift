import Foundation
import LocalisModels

/// Incremental parser for `text/event-stream` (SSE) payloads.
///
/// Pure and synchronous so it can be unit-tested without a live socket: feed it
/// raw chunks as they arrive off the wire, get back whole events. Bytes that do
/// not yet form a complete event are buffered until the rest arrives.
///
/// The parser is a value type — `parse` returns the events *and* the next
/// parser state rather than mutating in place.
public struct SSEParser: Equatable, Sendable {
    /// Bytes received so far that have not yet completed an event.
    public let buffer: String

    public init(buffer: String = "") {
        self.buffer = buffer
    }

    /// One parsed SSE frame.
    public struct Frame: Equatable, Sendable {
        /// The `event:` field, if the server sent one.
        public let event: String?
        /// The concatenated `data:` field(s).
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
    public func parse(_ chunk: String) -> (frames: [Frame], next: SSEParser) {
        let combined = buffer + chunk
        // Events are separated by a blank line. A trailing segment with no
        // terminator is an incomplete event — carry it into the next parse.
        let segments = combined.components(separatedBy: "\n\n")
        guard let remainder = segments.last else {
            return ([], SSEParser(buffer: combined))
        }

        let complete = segments.dropLast()
        let frames = complete.compactMap(Self.frame(from:))
        return (frames, SSEParser(buffer: remainder))
    }

    /// Parses one complete `field: value` block into a frame.
    ///
    /// Returns nil for comment-only or empty blocks (SSE keep-alives), which
    /// carry no payload and must not surface as events.
    private static func frame(from segment: String) -> Frame? {
        var event: String?
        var dataLines: [String] = []

        for line in segment.split(separator: "\n", omittingEmptySubsequences: true) {
            // `:` in column 0 marks a comment / keep-alive — ignore it.
            guard !line.hasPrefix(":") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }

            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            // SSE allows exactly one optional leading space after the colon.
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            default: continue
            }
        }

        guard !dataLines.isEmpty else { return nil }
        return Frame(event: event, data: dataLines.joined(separator: "\n"))
    }
}
