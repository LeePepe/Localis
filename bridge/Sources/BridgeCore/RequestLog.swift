import Foundation

/// What the bridge says out loud about the requests it served.
///
/// **Why this exists.** During integration the bridge could not answer the
/// simplest question asked of it — "did my phone's request reach you at all?" —
/// because it recorded nothing. That silence is not neutral: it is
/// indistinguishable from "the request went to the wrong path", from "TLS never
/// completed", and from "the bridge was not the process you think it was". A
/// diagnosis was offered on that basis and it was unfounded. One line per
/// request is what makes those three different observations instead of one
/// shrug.
///
/// **What it may not say (constitution §I).** No token, no message body, no
/// file path, no working directory, no peer address. The line is built from a
/// closed vocabulary — the ``Route`` cases — and never from the request's own
/// text:
///
/// - **The URI is never logged.** It is attacker-supplied. Echoing it puts text
///   of the caller's choosing into the operator's log, where a forged line can
///   claim whatever it likes about what happened.
/// - **Turn ids are never logged**, for the same reason: `/v1/turns/{id}/cancel`
///   carries the client's id, not ours, on the way in.
///
/// The method is logged as received but constrained to a fixed set, so an
/// unrecognised verb prints as `?` rather than as itself.
public enum RequestLog {
    /// Records one served request.
    public static func request(method: String, route: Route, status: Int) {
        write(line(at: Date(), method: method, route: route, status: status))
    }

    /// Records a connection that never became a request.
    ///
    /// A TLS handshake failure is the single most likely outcome of a pinning
    /// mismatch, and before this it produced no evidence whatsoever — the
    /// channel simply closed. **The fact of the failure is not the secret**; the
    /// peer address and the handshake details are, and neither appears here.
    public static func tlsHandshakeFailed() {
        write(handshakeLine(at: Date()))
    }

    // MARK: - Formatting

    /// The line for a served request.
    ///
    /// Pure and internal so it can be tested. The tests are the reason the
    /// leak-proofing above is a claim anyone can check rather than a comment.
    static func line(at time: Date, method: String, route: Route, status: Int) -> String {
        "\(stamp(time))  \(pad(verb(method), 7))  \(pad(route.logLabel, 14))\(status)"
    }

    static func handshakeLine(at time: Date) -> String {
        "\(stamp(time))  \(pad("---", 7))  \(pad("tls", 14))handshake failed"
    }

    /// The method, if it is one we recognise.
    ///
    /// Constrained rather than passed through: the method arrives from the
    /// socket, and an unbounded string is the same log-forging problem the URI
    /// has.
    private static func verb(_ method: String) -> String {
        let known = ["GET", "POST", "PUT", "DELETE", "HEAD", "PATCH", "OPTIONS"]
        let normalised = method.uppercased()
        return known.contains(normalised) ? normalised : "?"
    }

    /// Right-pads to `width`, and **never truncates**.
    ///
    /// `String.padding(toLength:)` truncates when the string is longer, which is
    /// not padding — it logged `DELETE` as `DELET` until a test caught it. A
    /// column that silently rewrites its contents to fit is worse than a ragged
    /// one, because the damage looks like a value rather than like a defect.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func stamp(_ time: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second], from: time)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Written to stdout, where the startup banner already goes, so an operator
    /// tailing one file sees the whole story.
    ///
    /// `FileHandle` rather than `print` for the same reason the banner uses it:
    /// stdout is block-buffered when it is not a terminal, and under `nohup` a
    /// buffered log is one that appears minutes after the thing it describes —
    /// or not at all, if the process is killed.
    private static func write(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }
}

public extension Route {
    /// This route's name in the log.
    ///
    /// **Every case is spelled out and none interpolates an associated value.**
    /// `cancelTurn(id:)` logs as `turn_cancel`, deliberately dropping the id:
    /// it came off the wire, so including it would let a caller write into the
    /// log. An exhaustive switch — rather than a default — means a route added
    /// later cannot quietly inherit a wrong label or a leaking one.
    var logLabel: String {
        switch self {
        case .pair: "pair"
        case .models: "models"
        case .skills: "skills"
        case .chatCompletions: "chat"
        case .cancelTurn: "turn_cancel"
        case .resumeTurn: "turn_resume"
        case .methodNotAllowed: "bad_method"
        case .notFound: "not_found"
        }
    }
}
