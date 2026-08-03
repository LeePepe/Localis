import Foundation
import LocalisModels

/// The client for **one** bridge (contract §2–§5, T025).
///
/// Everything here is scoped to a single machine: one token, one pinned
/// certificate, one negotiated protocol version, one backend list, one skill
/// catalogue. There is no way to address a second host through this type, and
/// that is the point — Amendment A puts multi-host orchestration above this
/// layer, and a client that could be pointed elsewhere is one refactor away from
/// sharing a token between machines (FR-028).
///
/// An `actor` because a turn is stateful: the cursor advances as events arrive,
/// and a stream and a cancel can be in flight at once.
public actor BridgeClient: AgentTransport {
    /// The protocol version this build speaks (contract §0).
    static let protocolVersion = 1

    private let host: HostID
    private let endpoint: HostEndpoint
    /// The bearer for this host. Nil means unpaired — every call refuses rather
    /// than putting an unauthenticated request on the wire.
    private let token: String?
    private let http: any HTTPStreaming
    private let mapper = StreamEventMapper()

    init(host: HostID, endpoint: HostEndpoint, token: String?, http: any HTTPStreaming) {
        self.host = host
        self.endpoint = endpoint
        self.token = token
        self.http = http
    }

    /// Builds a client for a paired host, reading its credentials from the
    /// Keychain under this host's key and no other (FR-028).
    public init(host: HostID, endpoint: HostEndpoint, credentials: HostCredentialStore) throws {
        let pin = try credentials.pin(for: host)
        self.init(
            host: host,
            endpoint: endpoint,
            token: try credentials.token(for: host),
            // No pin means no pairing, and `PinnedTrust` refuses on nil. Passing
            // it through rather than throwing keeps the refusal in the one place
            // that decides trust.
            http: PinnedHTTP(pin: pin)
        )
    }

    // MARK: - Chat

    /// Starts a turn (`POST /v1/chat/completions`).
    ///
    /// - Throws: before the stream begins, for a refused or unreadable response.
    ///   Failures *during* the stream surface through it, so content already
    ///   received is kept (FR-019).
    public func send(_ turn: TurnRequest) async throws -> TurnStream {
        let request = try self.request(
            path: "/v1/chat/completions",
            headers: [
                BridgeHeader.contentType: "application/json",
                BridgeHeader.sessionID: turn.sessionID.uuidString,
                // Only when the backend asked for one. Sending an empty header
                // is not the same as sending none.
                BridgeHeader.workspace: turn.workspace,
            ],
            body: try Self.body(for: turn)
        )

        return try await openStream(request, cursor: nil)
    }

    /// Resumes a turn after a disconnect (`POST /v1/turns/{id}/resume`).
    ///
    /// The cursor does double duty: it becomes `x-localis-resume-from`, and it
    /// filters the replay boundary where the bridge may resend frames the client
    /// already has. Both halves are needed for SC-003's "no missing text, no
    /// duplicated text".
    public func resume(_ cursor: TurnCursor) async throws -> TurnStream {
        let request = try self.request(
            path: "/v1/turns/\(Self.escape(cursor.turnID))/resume",
            headers: [
                // `resumeFrom` is the last *accepted* seq — the bridge replays
                // from seq+1. Nil when nothing has been accepted yet, where
                // sending "0" would skip the very first event.
                BridgeHeader.resumeFrom: cursor.resumeFrom.map(String.init),
            ]
        )

        return try await openStream(request, cursor: cursor)
    }

    /// Cancels a turn (`POST /v1/turns/{id}/cancel`).
    ///
    /// Idempotent by contract §4: a turn that already finished answers 200. The
    /// user tapping stop as the last token lands must not produce an error.
    public func cancel(turnID: String) async throws {
        let request = try self.request(path: "/v1/turns/\(Self.escape(turnID))/cancel")
        let (head, body) = try await perform(request)

        try await Self.checkStatus(head, body: body)
    }

    // MARK: - Catalogues

    /// This host's backends and its own capabilities (`GET /v1/models`).
    public func models() async throws -> BackendCatalog {
        try BackendCatalog(data: try await get("/v1/models"))
    }

    /// This host's skills (`GET /v1/skills`, Amendment B).
    ///
    /// Per host because skills are files on that machine: two hosts have two
    /// unrelated catalogues (FR-045).
    public func skills() async throws -> [SkillDescriptor] {
        try SkillCatalog.decode(data: try await get("/v1/skills"))
    }

    private func get(_ path: String) async throws -> Data {
        let (head, body) = try await perform(try request(path: path, method: "GET"))

        try await Self.checkStatus(head, body: body)
        return Data(try await Self.collect(body))
    }

    /// Whether this host can route to `backend` right now.
    ///
    /// Asks `/v1/models` rather than pinging the backend directly: availability
    /// is the host's to report (contract §2), and it is the only party that
    /// knows whether the backend is signed in. A backend the host no longer
    /// lists is not available — it was removed, and treating a missing entry as
    /// reachable would offer the user a backend that cannot answer.
    ///
    /// Any failure reads as "not right now". A probe exists to grey a row out,
    /// and throwing from it would turn an unreachable host into an error the
    /// user has to dismiss before seeing the list at all.
    public func probe(_ backend: AgentBackend) async -> Bool {
        guard let catalog = try? await models() else { return false }

        return catalog.backends.first { $0.id == backend.id }?.isAvailable ?? false
    }

    // MARK: - Streaming

    /// Opens a stream, checking status and protocol before yielding anything.
    ///
    /// Both checks happen before the first event on purpose: a turn that is
    /// going to be refused should be refused as a thrown error, where the caller
    /// has to handle it, rather than as a stream that yields nothing and ends.
    private func openStream(_ request: URLRequest, cursor: TurnCursor?) async throws -> TurnStream {
        let (head, body) = try await perform(request)

        try await Self.checkStatus(head, body: body)

        return TurnStream(
            turnID: head.value(BridgeHeader.turnID),
            events: events(from: body, cursor: cursor)
        )
    }

    /// Turns raw bytes into domain events.
    ///
    /// Three rules live here and nowhere else:
    /// - `[DONE]` closes the stream; anything after it is ignored (contract §7).
    /// - The stream ending without `[DONE]` is `connectionLost`, not success —
    ///   finishing cleanly would present half an answer as whole.
    /// - `truncated` ends the turn as truncated, never complete (§3.3).
    private func events(
        from body: AsyncThrowingStream<[UInt8], Error>,
        cursor: TurnCursor?
    ) -> AsyncThrowingStream<SequencedEvent, Error> {
        let mapper = mapper

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var cursor = cursor
                var sawDone = false

                /// - Returns: whether the stream should keep reading.
                func emit(_ frames: [SSEParser.Frame]) -> Bool {
                    for frame in frames {
                        if Self.isTruncation(frame) {
                            continuation.finish(throwing: LocalisError.truncated)
                            return false
                        }

                        guard let event = mapper.map(frame) else { continue }

                        if case .done = event.event {
                            continuation.yield(event)
                            continuation.finish()
                            sawDone = true
                            return false
                        }

                        // Dedup at the replay boundary. Compared against the
                        // turn *and* the seq: seq counts per turn, so another
                        // turn's frame carries numbers in the same range and
                        // would otherwise advance this turn's cursor.
                        if let seq = event.seq, let current = cursor {
                            guard current.accepts(turnID: current.turnID, seq: seq) else { continue }
                            cursor = current.advanced(to: seq)
                        }

                        continuation.yield(event)
                    }
                    return true
                }

                do {
                    for try await chunk in body {
                        let (frames, next) = parser.parse(bytes: chunk)
                        parser = next

                        guard emit(frames) else { return }

                        // The parser refuses to grow without bound; past its cap
                        // the bytes are no longer a stream we can frame.
                        if parser.hasOverflowed {
                            continuation.finish(throwing: LocalisError.truncated)
                            return
                        }
                    }

                    guard emit(parser.finish()), !sawDone else { return }

                    // The connection ended without `[DONE]`. What arrived is
                    // kept — the caller has already received it — but the turn
                    // is not complete, and saying so is the difference between
                    // "interrupted, retry" and a half answer shown as finished.
                    continuation.finish(throwing: LocalisError.connectionLost)
                } catch is CancellationError {
                    continuation.finish(throwing: LocalisError.cancelled)
                } catch {
                    continuation.finish(throwing: LocalisError.connectionLost)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether a frame reports the host's buffer cap was hit (contract §3.3).
    private static func isTruncation(_ frame: SSEParser.Frame) -> Bool {
        JSONValue(jsonText: frame.data)?["x_localis"]?["truncated"]?.boolValue == true
    }

    // MARK: - Requests

    /// Builds a request for this host, bearer and protocol header attached.
    ///
    /// - Throws: `LocalisError.unauthorized` when the host is not paired. The
    ///   check is here rather than at each call site so a new endpoint cannot
    ///   forget it and go out unauthenticated.
    private func request(
        path: String,
        method: String = "POST",
        headers: [String: String?] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        guard let token, !token.isEmpty else { throw LocalisError.unauthorized }

        var components = URLComponents()
        // Constitution V: https is not a default here, it is the only value.
        // There is no branch that could produce anything else.
        components.scheme = "https"
        components.host = endpoint.host
        components.port = endpoint.port
        // `percentEncodedPath`, because the turn id is already escaped by the
        // caller. Assigning to `path` would encode it a second time and turn
        // `t-9` into `t%252D9` — a 404 from the bridge with nothing in the
        // message to say why.
        components.percentEncodedPath = path

        guard let url = components.url else {
            throw LocalisError.invalidInput(field: "endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: BridgeHeader.authorization)
        request.setValue(String(Self.protocolVersion), forHTTPHeaderField: BridgeHeader.protocolVersion)
        for (name, value) in headers {
            guard let value, !value.isEmpty else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        return request
    }

    /// The standard OpenAI request body (contract §3).
    ///
    /// `model` is the wire id as the host spelled it. It is never interpreted:
    /// constitution IV makes backends data, so this file does not know which
    /// backends exist and must not learn.
    private static func body(for turn: TurnRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": turn.backendID,
            "stream": true,
            "messages": turn.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            // v1 always asks. `auto` would let the Mac run tools without the
            // user ever seeing the request (contract §3).
            "x_localis": ["approval_policy": "ask"],
        ])
    }

    /// Percent-escapes a path segment.
    ///
    /// `turn_id` is opaque and generated elsewhere; the contract requires it to
    /// be unpredictable, which means it may contain anything. Interpolating it
    /// raw would let a `/` in an id address a different endpoint entirely.
    ///
    /// The allowed set is RFC 3986's *unreserved* characters rather than
    /// `.alphanumerics`: escaping `-`, `.`, `_` and `~` is legal but pointless,
    /// and it makes an ordinary id like `t-9` unrecognisable in a request log
    /// the bridge author is reading.
    private static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? segment
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private func perform(
        _ request: URLRequest
    ) async throws -> (HTTPResponseHead, AsyncThrowingStream<[UInt8], Error>) {
        do {
            return try await http.stream(request)
        } catch let error as LocalisError {
            throw error
        } catch {
            // A socket-level failure. Reporting it as a bad response would send
            // the user to look at the bridge instead of the network.
            throw LocalisError.unreachable
        }
    }

    // MARK: - Responses

    /// Rejects a response before any of it is trusted.
    ///
    /// Protocol first: a version mismatch explains every other oddity in the
    /// body, and mapping it to a parse error would send the user to debug a
    /// payload that is fine for the version that sent it.
    private static func checkStatus(
        _ head: HTTPResponseHead,
        body: AsyncThrowingStream<[UInt8], Error>
    ) async throws {
        if let side = upgradeSide(head) {
            throw LocalisError.protocolUpgradeRequired(side: side)
        }

        guard !(200..<300).contains(head.status) else { return }

        // Only now is the body read, and only for `error.code`. `error.message`
        // is never touched: it may hold absolute paths (constitution I, §6), and
        // a value that is never read cannot leak.
        let payload = JSONValue(jsonData: Data(try await collect(body)))?["error"]
        let code = payload?["code"]?.stringValue

        throw error(status: head.status, code: code, reason: payload?["unavailable_reason"]?.stringValue)
    }

    /// Which end is behind, or nil when the versions are compatible.
    ///
    /// A missing header is compatible on purpose: it is the bridge's statement
    /// about itself, and treating silence as incompatibility would lock the user
    /// out of a working host over an absent header. An unparseable value is the
    /// same case.
    private static func upgradeSide(_ head: HTTPResponseHead) -> LocalisError.UpgradeSide? {
        guard let raw = head.value(BridgeHeader.protocolVersion), let version = Int(raw) else {
            return nil
        }

        if version > protocolVersion { return .app }
        if version < protocolVersion { return .bridge }
        return nil
    }

    /// Maps status and code to the error the UI can act on (contract §6).
    ///
    /// Keyed on the pair, not on status alone: 401 splits into "wrong token" and
    /// "token revoked", which demand opposite actions — one clears the Keychain
    /// entry and the other must not.
    private static func error(status: Int, code: String?, reason: String?) -> LocalisError {
        switch (status, code) {
        case (401, "token_revoked"): return .tokenRevoked
        case (401, _): return .unauthorized
        case (403, _): return .turnNotYours
        case (404, "unknown_turn"): return .unknownTurn
        case (404, _): return .unknownBackend
        case (409, _): return .sessionBusy
        case (410, _): return .turnExpired
        case (426, _): return .protocolUpgradeRequired(side: .app)
        case (503, _): return .backendUnavailable(reason: reason)
        default:
            // A status this contract does not define. Guessing at it would map a
            // 500 to something specific and actionable that it is not.
            return .malformedResponse
        }
    }

    private static func collect(_ body: AsyncThrowingStream<[UInt8], Error>) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for try await chunk in body { bytes += chunk }
        return bytes
    }
}

/// One turn to send to a host (contract §3).
///
/// `backendID` is the wire id, kept as the host spelled it. It is deliberately
/// **not** a `BackendRef`: a client already belongs to one host, so carrying the
/// host id again would create a second place for it to disagree with the client
/// it was sent through.
public struct TurnRequest: Sendable, Hashable {
    public let backendID: String
    /// Maps this conversation onto the bridge's own session, so a turn continues
    /// where the last one stopped (contract §3).
    public let sessionID: UUID
    /// The conversation so far, oldest first, ending with what to answer.
    public let messages: [Message]
    /// Sent only for backends advertising the `workspace` capability.
    public let workspace: String?

    public init(backendID: String, sessionID: UUID, messages: [Message], workspace: String? = nil) {
        self.backendID = backendID
        self.sessionID = sessionID
        self.messages = messages
        self.workspace = workspace
    }
}
