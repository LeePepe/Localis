import Foundation
import Testing

@testable import TransportKit

/// Table-driven coverage for SSE framing.
///
/// Contract §7 names this the most bug-prone surface in the client, so the
/// cases here are deliberately hostile: frames sliced at every byte boundary,
/// `\r\n` mixed with `\n`, keep-alives, unknown event names, and multi-byte
/// characters cut in half by the network.
@Suite("SSEParser — framing")
struct SSEParserFramingTests {
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

        #expect(parser.isEmpty)
    }

    // MARK: - Line terminators

    /// The contract requires tolerating `\r\n`, `\n`, and bare `\r`, including
    /// a stream that mixes them. A bridge behind a proxy can rewrite them.
    ///
    /// Drained through `finish()` because a trailing bare CR is ambiguous until
    /// the connection ends — see `finish()` and `crlfSplitAcrossChunks`.
    @Test("handles CRLF, LF, and bare CR terminators", arguments: [
        ("CRLF", "event: message\r\ndata: hello\r\n\r\n"),
        ("LF", "event: message\ndata: hello\n\n"),
        ("CR", "event: message\rdata: hello\r\r"),
        ("mixed CRLF then LF", "event: message\r\ndata: hello\n\n"),
        ("mixed LF then CRLF", "event: message\ndata: hello\r\n\r\n"),
    ])
    func handlesAllTerminators(_ testCase: (name: String, wire: String)) {
        let (frames, parser) = SSEParser().parse(testCase.wire)
        let all = frames + parser.finish()

        #expect(all.count == 1, "\(testCase.name): expected exactly one frame")
        #expect(all[0].event == "message", "\(testCase.name)")
        #expect(all[0].data == "hello", "\(testCase.name)")
    }

    /// A CRLF split *between* the CR and the LF is the classic framing bug: a
    /// parser that treats the lone CR as a terminator emits a phantom blank
    /// line and closes the frame early.
    @Test("a CRLF split across chunks is still one terminator")
    func crlfSplitAcrossChunks() {
        let (first, parser) = SSEParser().parse("data: hello\r")
        #expect(first.isEmpty)

        let (second, parser2) = parser.parse("\ndata: world\r")
        #expect(second.isEmpty, "the lone CR must not close the frame")

        let (third, _) = parser2.parse("\n\r\n")
        #expect(third.count == 1)
        #expect(third[0].data == "hello\nworld")
    }

    // MARK: - Chunk boundaries

    /// Feeds one wire payload through every possible split point. Any framing
    /// bug that depends on where the network happened to cut shows up here.
    @Test("frames identically at every possible chunk boundary")
    func everyChunkBoundary() {
        let wire = "event: x-localis-tool-call\ndata: {\"tool\":\"Bash\"}\n\ndata: hello\n\ndata: [DONE]\n\n"
        let bytes = Array(wire.utf8)
        let expected = [
            SSEParser.Frame(event: "x-localis-tool-call", data: "{\"tool\":\"Bash\"}"),
            SSEParser.Frame(event: nil, data: "hello"),
            SSEParser.Frame(event: nil, data: "[DONE]"),
        ]

        for split in 0...bytes.count {
            var parser = SSEParser()
            var collected: [SSEParser.Frame] = []

            for piece in [Array(bytes[..<split]), Array(bytes[split...])] {
                let (frames, next) = parser.parse(bytes: piece)
                collected += frames
                parser = next
            }

            #expect(collected == expected, "split at byte \(split) reframed the stream")
        }
    }

    /// Byte-at-a-time delivery — the worst case a slow link can produce.
    @Test("frames identically when delivered one byte at a time")
    func byteAtATime() {
        let wire = "data: {\"delta\":\"He\"}\n\ndata: {\"delta\":\"llo\"}\n\n"
        var parser = SSEParser()
        var collected: [SSEParser.Frame] = []

        for byte in Array(wire.utf8) {
            let (frames, next) = parser.parse(bytes: [byte])
            collected += frames
            parser = next
        }

        #expect(collected.map(\.data) == ["{\"delta\":\"He\"}", "{\"delta\":\"llo\"}"])
    }

    /// A multi-byte character cut in half by a TCP packet boundary. Decoding
    /// each chunk as UTF-8 *before* framing turns this into U+FFFD — the
    /// user sees a corrupted character that no amount of retrying fixes. The
    /// parser must therefore buffer bytes, not `String`s.
    @Test("a multi-byte character split across chunks survives intact")
    func multiByteSplitAcrossChunks() {
        let wire = "data: 你好世界\n\n"
        let bytes = Array(wire.utf8)

        for split in 0...bytes.count {
            var parser = SSEParser()
            var collected: [SSEParser.Frame] = []

            for piece in [Array(bytes[..<split]), Array(bytes[split...])] {
                let (frames, next) = parser.parse(bytes: piece)
                collected += frames
                parser = next
            }

            #expect(collected.map(\.data) == ["你好世界"], "split at byte \(split) corrupted UTF-8")
        }
    }

    @Test("emoji split across chunks survives intact")
    func emojiSplitAcrossChunks() {
        let bytes = Array("data: 🎉\n\n".utf8)
        let (first, parser) = SSEParser().parse(bytes: Array(bytes[..<8]))
        #expect(first.isEmpty)

        let (second, _) = parser.parse(bytes: Array(bytes[8...]))
        #expect(second.map(\.data) == ["🎉"])
    }

    // MARK: - Field parsing

    @Test("keeps exactly one optional space after the colon")
    func stripsOneLeadingSpace() {
        let (frames, _) = SSEParser().parse("data:  two spaces\n\n")

        #expect(frames[0].data == " two spaces")
    }

    @Test("a field with no colon has an empty value")
    func fieldWithoutColon() {
        // Per the SSE spec a bare line is a field name with an empty value.
        // `data` alone therefore contributes an empty line, not nothing.
        let (frames, _) = SSEParser().parse("data\ndata: after\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].data == "\nafter")
    }

    @Test("ignores unknown fields but keeps the frame")
    func ignoresUnknownFields() {
        let (frames, _) = SSEParser().parse("id: 7\nretry: 500\nfoo: bar\ndata: kept\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].data == "kept")
    }

    @Test("an unknown event name still produces a frame")
    func unknownEventName() {
        // Forward compatibility (FR-010): the transport surfaces the frame and
        // lets the mapper decide to drop it. Dropping it here would make new
        // bridge events invisible to the layer that knows about them.
        let (frames, _) = SSEParser().parse("event: x-localis-invented-later\ndata: {}\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "x-localis-invented-later")
    }

    @Test("a frame with fields but no data yields nothing")
    func noDataYieldsNoFrame() {
        // `event:` with no `data:` is not dispatchable per the SSE spec.
        let (frames, _) = SSEParser().parse("event: ping\n\n")

        #expect(frames.isEmpty)
    }

    @Test("an empty data field yields a frame with empty data")
    func emptyDataField() {
        let (frames, _) = SSEParser().parse("data:\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].data == "")
    }

    @Test("strips a UTF-8 BOM at the start of the stream")
    func stripsBOM() {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes += Array("data: hello\n\n".utf8)

        let (frames, _) = SSEParser().parse(bytes: bytes)

        #expect(frames.map(\.data) == ["hello"])
    }

    @Test("consecutive blank lines do not emit empty frames")
    func consecutiveBlankLines() {
        let (frames, _) = SSEParser().parse("\n\n\n\ndata: hello\n\n\n\n")

        #expect(frames.map(\.data) == ["hello"])
    }

    @Test("invalid UTF-8 in a frame is replaced, not fatal")
    func invalidUTF8IsLossy() {
        // A corrupt byte must not take down the stream: the frame is decoded
        // lossily and the connection keeps running. Throwing here would let
        // one bad byte end a turn that is otherwise fine.
        var bytes = Array("data: ".utf8)
        bytes += [0xFF, 0xFE]
        bytes += Array("\n\n".utf8)

        let (frames, _) = SSEParser().parse(bytes: bytes)

        #expect(frames.count == 1)
    }

    // MARK: - End of stream

    @Test("finish drains a frame left on a trailing bare CR")
    func finishDrainsTrailingCR() {
        let (frames, parser) = SSEParser().parse("data: hello\r\r")
        #expect(frames.isEmpty, "the trailing CR is ambiguous until the stream ends")

        #expect(parser.finish().map(\.data) == ["hello"])
    }

    @Test("finish discards a frame with no terminator")
    func finishDiscardsIncompleteFrame() {
        // These bytes may be the front half of a chunk the bridge never
        // finished sending. Emitting them would hand the mapper truncated JSON
        // and turn a clean disconnect into a parse error.
        let (frames, parser) = SSEParser().parse("data: {\"choices\":[{\"delta\":{\"cont")
        #expect(frames.isEmpty)

        #expect(parser.finish().isEmpty)
    }

    @Test("finish on an empty parser yields nothing")
    func finishOnEmptyParser() {
        #expect(SSEParser().finish().isEmpty)
    }

    // MARK: - Buffer bounds

    @Test("reports an oversized buffer instead of growing without bound")
    func rejectsUnboundedBuffer() {
        // A bridge that never sends a blank line would otherwise grow this
        // buffer until the app is killed. The parser reports the overflow so
        // the session can fail with a typed error.
        let parser = SSEParser(limit: 64)
        let (frames, next) = parser.parse(String(repeating: "x", count: 200))

        #expect(frames.isEmpty)
        #expect(next.hasOverflowed)
    }

    @Test("a buffer under the limit does not report overflow")
    func underLimitIsFine() {
        let parser = SSEParser(limit: 64)
        let (_, next) = parser.parse("data: small")

        #expect(next.hasOverflowed == false)
    }
}
