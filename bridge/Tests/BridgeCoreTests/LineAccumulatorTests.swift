import Foundation
import Testing

@testable import BridgeCore

/// Splitting a byte stream into lines.
///
/// This looks trivial and is not: a subprocess writes when its buffer fills,
/// not when a line ends, so a single read can carry half a line and a read
/// boundary can land mid-UTF-8. Getting it wrong shows up as JSON that
/// intermittently fails to parse under load — the hardest class of bug to
/// reproduce, because it depends on pipe timing rather than on input.
@Suite("LineAccumulator — chunked stream framing")
struct LineAccumulatorTests {
    /// The base case, so the harder ones have something to be a deviation from.
    @Test("whole lines in one chunk come out whole")
    func wholeLines() {
        var accumulator = LineAccumulator()

        #expect(accumulator.append(Data("a\nb\n".utf8)) == ["a", "b"])
    }

    /// **The case that matters.** A line split across two reads must emerge as
    /// one line, not two fragments — each of which would fail to parse as JSON
    /// and be reported as a dialect mismatch.
    @Test("a line split across chunks is rejoined")
    func splitLine() {
        var accumulator = LineAccumulator()

        #expect(accumulator.append(Data("{\"ty".utf8)).isEmpty)
        #expect(accumulator.append(Data("pe\":\"x\"}\n".utf8)) == ["{\"type\":\"x\"}"])
    }

    /// An unterminated tail is not a line yet. Emitting it early is the same
    /// bug as above, arrived at from the other direction.
    @Test("a partial tail is withheld until terminated")
    func partialTail() {
        var accumulator = LineAccumulator()

        #expect(accumulator.append(Data("done\npart".utf8)) == ["done"])
        #expect(accumulator.append(Data("ial\n".utf8)) == ["partial"])
    }

    /// A multi-byte character split across a read boundary must not become a
    /// replacement character. Decoding each chunk independently would corrupt
    /// it — the bytes have to be joined before they are interpreted.
    @Test("a multi-byte character split across chunks survives")
    func splitMultiByteCharacter() {
        var accumulator = LineAccumulator()
        let bytes = Array("你好\n".utf8)

        #expect(accumulator.append(Data(bytes[0..<4])).isEmpty)

        let lines = accumulator.append(Data(bytes[4...]))
        #expect(lines == ["你好"])
    }

    /// The CLI may end its last line with EOF rather than a newline. Without an
    /// explicit flush that final line — which for claude is the `result` frame
    /// carrying usage and the turn's outcome — would be silently discarded.
    @Test("flush yields the unterminated final line")
    func flushYieldsTail() {
        var accumulator = LineAccumulator()

        #expect(accumulator.append(Data("last".utf8)).isEmpty)
        #expect(accumulator.flush() == ["last"])
        // Idempotent: a second flush must not replay the line, or a caller that
        // flushes defensively would process the result frame twice.
        #expect(accumulator.flush().isEmpty)
    }

    /// Windows-style terminators would otherwise leave a trailing `\r` inside
    /// the line, which survives JSON parsing and reappears as a stray character
    /// in the user's transcript.
    @Test("carriage returns are stripped from line ends")
    func stripsCarriageReturns() {
        var accumulator = LineAccumulator()

        #expect(accumulator.append(Data("a\r\nb\r\n".utf8)) == ["a", "b"])
    }

    /// Empty lines are framing. Passing them on would make every decoder
    /// downstream repeat the same guard.
    @Test("empty lines are dropped")
    func dropsEmptyLines() {
        var accumulator = LineAccumulator()

        #expect(accumulator.append(Data("a\n\n\nb\n".utf8)) == ["a", "b"])
    }
}
