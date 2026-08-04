import Foundation
import Testing

@testable import BridgeCore

/// What the request log records, and — more importantly — what it refuses to.
///
/// This suite exists because the log was added mid-integration to answer "did
/// the request arrive?", and a log added under that pressure is exactly the kind
/// that grows a `\(uri)` in it later. Constitution §I is not a comment here; the
/// tests below fail if it stops being true.
@Suite("RequestLog")
struct RequestLogTests {
    private static let noon = Date(timeIntervalSince1970: 0)

    /// The line an operator actually reads: when, what, and how it ended.
    @Test("a served request logs its method, route and status")
    func servedRequestIsReadable() {
        let line = RequestLog.line(at: Self.noon, method: "POST", route: .pair, status: 200)

        #expect(line.contains("POST"))
        #expect(line.contains("pair"))
        #expect(line.contains("200"))
    }

    /// **The load-bearing test.** Every route logs a label from a closed
    /// vocabulary, and the two routes that carry a client-chosen id must not
    /// carry it into the log.
    ///
    /// The id below is what a hostile caller would send: it is not an id, it is
    /// a forged log line. If `logLabel` ever interpolates its associated value,
    /// this line appears in the operator's log claiming a pairing succeeded.
    @Test("a client-supplied turn id never reaches the log")
    func turnIDIsNotLogged() {
        let forged = "00:00:00  POST   pair            200 ATTACKER"

        for route in [Route.cancelTurn(id: forged), .resumeTurn(id: forged)] {
            let line = RequestLog.line(at: Self.noon, method: "POST", route: route, status: 200)

            #expect(!line.contains("ATTACKER"), "the log echoed a client-supplied turn id: \(line)")
            #expect(!line.contains(forged))
        }
    }

    /// The same problem through the other client-controlled field.
    ///
    /// A method is a short token in practice, but nothing on the socket enforces
    /// that. An unrecognised verb must print as a placeholder, not as itself.
    @Test("an unrecognised method is not echoed")
    func unknownMethodIsNotEchoed() {
        let forged = "GET\n00:00:00  POST   pair            200"
        let line = RequestLog.line(at: Self.noon, method: forged, route: .models, status: 200)

        #expect(!line.contains("\n"), "the log accepted a newline from the wire: \(line)")
        #expect(line.contains("?"))
    }

    /// Known verbs still read normally — the guard above must not have made the
    /// log useless.
    ///
    /// **`DELETE` is here because it failed.** The first version padded with
    /// `String.padding(toLength:)`, which *truncates* when the string is longer
    /// than the width, so `DELETE` was logged as `DELET`. A column that quietly
    /// rewrites its contents to fit produces a log that reads as data and is
    /// wrong — the worst failure a diagnostic tool can have, since it is
    /// consulted precisely when nothing else is trustworthy. Keep a
    /// longer-than-the-column verb in this list.
    @Test("known methods are logged as themselves", arguments: ["GET", "POST", "DELETE", "OPTIONS"])
    func knownMethodsSurvive(method: String) {
        #expect(RequestLog.line(at: Self.noon, method: method, route: .models, status: 200).contains(method))
    }

    /// The same truncation risk on the other column. `turn_cancel` is the
    /// longest label, and it must appear whole.
    @Test("the longest route label is not truncated")
    func longestLabelSurvives() {
        let line = RequestLog.line(at: Self.noon, method: "POST", route: .cancelTurn(id: "x"), status: 202)

        #expect(line.contains("turn_cancel"), "the route column truncated its label: \(line)")
        #expect(line.contains("202"))
    }

    /// Lower-case from the wire is the same request. Logging `get` and `GET` as
    /// different things would make the log's own vocabulary open again.
    @Test("method case is normalised")
    func methodCaseNormalised() {
        #expect(RequestLog.line(at: Self.noon, method: "post", route: .models, status: 200).contains("POST"))
    }

    /// Every route has a label, and no label leaks. Enumerated rather than
    /// sampled so a route added later without a `logLabel` case fails to
    /// compile, and one added with a bad label fails here.
    @Test("every route has a non-empty label")
    func everyRouteHasALabel() {
        let routes: [Route] = [
            .pair, .models, .skills, .chatCompletions,
            .cancelTurn(id: "x"), .resumeTurn(id: "x"),
            .methodNotAllowed, .notFound,
        ]

        for route in routes {
            #expect(!route.logLabel.isEmpty)
            #expect(!route.logLabel.contains("x"), "\(route) leaked its associated value")
        }
    }

    /// A handshake failure is recorded as having happened, and nothing about who
    /// it happened with. The peer address is the part that is not ours (§I); the
    /// fact is what makes a pinning mismatch diagnosable at all.
    @Test("a handshake failure is recorded without a peer")
    func handshakeFailureIsRecorded() {
        let line = RequestLog.handshakeLine(at: Self.noon)

        #expect(line.contains("tls"))
        #expect(line.contains("handshake failed"))
    }
}
