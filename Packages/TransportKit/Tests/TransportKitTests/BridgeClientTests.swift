import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// One host's client: chat, resume, cancel, catalogues (T025, contract §2–§4).
///
/// The rules under test here are the ones that fail *quietly*. A turn that
/// resumes from the wrong cursor loses a sentence; a disconnect read as a cancel
/// throws away work the Mac already did; a status code mapped to the wrong error
/// sends the user to fix the wrong thing. None of them throw on their own.
@Suite("BridgeClient — one host")
struct BridgeClientTests {
    private static let host = HostID()
    private static let endpoint = HostEndpoint(host: "mac.local", port: 8443)

    private static func client(
        _ http: StubStreamingHTTP,
        token: String? = "opaque-token"
    ) -> BridgeClient {
        BridgeClient(host: host, endpoint: endpoint, token: token, http: http)
    }

    private static func turn(_ text: String = "hello") -> TurnRequest {
        TurnRequest(
            backendID: "alpha",
            sessionID: UUID(),
            messages: [Message(id: UUID(), role: .user, text: text, createdAt: Date(timeIntervalSince1970: 0))]
        )
    }

    private static func collect(
        _ stream: AsyncThrowingStream<SequencedEvent, Error>
    ) async throws -> [SequencedEvent] {
        var received: [SequencedEvent] = []
        for try await event in stream { received.append(event) }
        return received
    }

    private static func text(_ events: [SequencedEvent]) -> String {
        events.reduce(into: "") { result, event in
            if case .delta(let chunk) = event.event { result += chunk }
        }
    }

    // MARK: - Request shape

    @Test("a chat request carries the bearer, the protocol and the session")
    func chatRequestShape() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: ["data: [DONE]\n\n"])])
        let request = Self.turn()

        _ = try await Self.collect(Self.client(http).send(request).events)

        let sent = try #require(await http.lastRequest)
        #expect(sent.url?.absoluteString == "https://mac.local:8443/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token")
        #expect(sent.value(forHTTPHeaderField: "x-localis-protocol") == "1")
        #expect(sent.value(forHTTPHeaderField: "x-localis-session-id") == request.sessionID.uuidString)
    }

    @Test("the body is a standard OpenAI streaming request")
    func chatRequestBody() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: ["data: [DONE]\n\n"])])

        _ = try await Self.collect(Self.client(http).send(Self.turn("hi")).events)

        let body = try #require(await http.lastRequest?.httpBody)
        let json = try #require(JSONValue(jsonData: body))
        #expect(json["model"]?.stringValue == "alpha")
        #expect(json["stream"]?.boolValue == true)
        #expect(json["messages"]?.arrayValue?.first?["role"]?.stringValue == "user")
        #expect(json["messages"]?.arrayValue?.first?["content"]?.stringValue == "hi")
        // v1 always asks. An `auto` policy would let the Mac run tools without
        // the user ever being shown the request.
        #expect(json["x_localis"]?["approval_policy"]?.stringValue == "ask")
    }

    @Test("an unpaired host is refused before any request is made")
    func unpairedHostRefused() async {
        // No token means not paired. Sending anyway would put an unauthenticated
        // request on the wire and surface as a confusing 401 from the bridge.
        let http = StubStreamingHTTP(responses: [])

        await #expect(throws: LocalisError.unauthorized) {
            _ = try await Self.client(http, token: nil).send(Self.turn())
        }
        #expect(await http.lastRequest == nil)
    }

    // MARK: - Streaming

    @Test("deltas arrive in order and reassemble to the full text")
    func streamsDeltas() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"data: {"seq":0,"choices":[{"delta":{"content":"He"},"index":0}]}"# + "\n\n",
            #"data: {"seq":1,"choices":[{"delta":{"content":"llo"},"index":0}]}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])

        let events = try await Self.collect(Self.client(http).send(Self.turn()).events)

        #expect(Self.text(events) == "Hello")
        #expect(events.map(\.seq) == [0, 1, nil])
    }

    @Test("a delta split across packet boundaries survives intact")
    func streamsAcrossPacketBoundaries() async throws {
        // Contract §7. The bridge sends one frame; the network delivers it in
        // three pieces, one of which cuts a multi-byte character in half.
        let frame = #"data: {"seq":0,"choices":[{"delta":{"content":"héllo"},"index":0}]}"# + "\n\n"
        let bytes = Array(frame.utf8)
        // `#require`, not `!`: if the literal above is ever reworded without an
        // "é" the force unwrap crashes the whole suite, and a crashed run is
        // read as infrastructure trouble rather than as this test's finding.
        let cut = try #require(bytes.firstIndex(of: 0xC3)) + 1   // between the two bytes of "é"

        let http = StubStreamingHTTP(responses: [.streamBytes(status: 200, headers: [:], chunks: [
            Array(bytes[..<cut]),
            Array(bytes[cut...]),
            Array("data: [DONE]\n\n".utf8),
        ])])

        let events = try await Self.collect(Self.client(http).send(Self.turn()).events)

        #expect(Self.text(events) == "héllo")
    }

    @Test("an unknown event name is skipped and the stream continues")
    func unknownEventSkipped() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            "event: x-localis-invented-later\ndata: {\"seq\":0}\n\n",
            #"data: {"seq":1,"choices":[{"delta":{"content":"ok"},"index":0}]}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])

        let events = try await Self.collect(Self.client(http).send(Self.turn()).events)

        #expect(Self.text(events) == "ok")
    }

    @Test("data after [DONE] is ignored")
    func dataAfterDoneIgnored() async throws {
        // Contract §7. A late frame must not append to a message the client has
        // already closed.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"data: {"seq":0,"choices":[{"delta":{"content":"done"},"index":0}]}"# + "\n\n",
            "data: [DONE]\n\n",
            #"data: {"seq":1,"choices":[{"delta":{"content":" extra"},"index":0}]}"# + "\n\n",
        ])])

        let events = try await Self.collect(Self.client(http).send(Self.turn()).events)

        #expect(Self.text(events) == "done")
        #expect(events.last?.event == .done)
    }

    @Test("a stream that ends without [DONE] reports the connection as lost")
    func truncatedStreamReportsLoss() async throws {
        // Contract §7: content received is kept, and the turn is *not* complete.
        // Ending the stream cleanly here would present a half answer as whole.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"data: {"seq":0,"choices":[{"delta":{"content":"half"},"index":0}]}"# + "\n\n",
        ])])

        var received: [SequencedEvent] = []
        var thrown: (any Error)?
        do {
            for try await event in try await Self.client(http).send(Self.turn()).events { received.append(event) }
        } catch {
            thrown = error
        }

        #expect(Self.text(received) == "half", "everything received is kept")
        #expect(thrown as? LocalisError == .connectionLost)
    }

    @Test("truncation past the host's buffer cap is never reported as completion")
    func truncationIsNotCompletion() async throws {
        // Contract §3.3: "宁可说丢了,不可假装完整".
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"data: {"seq":0,"choices":[{"delta":{"content":"partial"},"index":0}]}"# + "\n\n",
            #"data: {"seq":1,"x_localis":{"truncated":true}}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])

        var received: [SequencedEvent] = []
        var thrown: (any Error)?
        do {
            for try await event in try await Self.client(http).send(Self.turn()).events { received.append(event) }
        } catch {
            thrown = error
        }

        #expect(Self.text(received) == "partial")
        #expect(thrown as? LocalisError == .truncated)
    }

    // MARK: - Turn identity

    @Test("the turn id is readable from the header before any body arrives")
    func turnIDFromHeader() async throws {
        // Contract §3.3 prefers the header precisely so the client can record it
        // before the first event — a turn whose id is only in the body is
        // unresumable if the connection dies before that body lands.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200,
            headers: ["x-localis-turn-id": "t-9"],
            body: ["data: [DONE]\n\n"]
        )])

        let stream = try await Self.client(http).send(Self.turn())

        #expect(stream.turnID == "t-9")
    }

    @Test("header casing does not hide the turn id")
    func turnIDHeaderCaseInsensitive() async throws {
        // HTTP header names are case-insensitive and proxies rewrite them. A
        // case-sensitive lookup would silently make turns unresumable.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200,
            headers: ["X-Localis-Turn-Id": "t-9"],
            body: ["data: [DONE]\n\n"]
        )])

        #expect(try await Self.client(http).send(Self.turn()).turnID == "t-9")
    }

    @Test("a host that sends no turn id yields nil rather than a placeholder")
    func turnIDAbsent() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: ["data: [DONE]\n\n"])])

        #expect(try await Self.client(http).send(Self.turn()).turnID == nil)
    }

    // MARK: - Resume (Amendment C §3.3)

    @Test("resume asks for everything after the last confirmed seq")
    func resumeSendsCursor() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: ["data: [DONE]\n\n"])])
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 42)

        _ = try await Self.collect(Self.client(http).resume(cursor).events)

        let sent = try #require(await http.lastRequest)
        #expect(sent.url?.absoluteString == "https://mac.local:8443/v1/turns/t-9/resume")
        #expect(sent.httpMethod == "POST")
        // The *last accepted* seq, not the next wanted one — the bridge replays
        // from seq+1, so sending 43 here would skip event 43 entirely.
        #expect(sent.value(forHTTPHeaderField: "x-localis-resume-from") == "42")
    }

    @Test("resuming a turn with nothing accepted yet sends no cursor header")
    func resumeWithoutCursor() async throws {
        // `nil` is not `0`: seq counts from 0, so sending "0" would ask the
        // bridge to skip the very first event.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: ["data: [DONE]\n\n"])])

        _ = try await Self.collect(Self.client(http).resume(TurnCursor(turnID: "t-9")).events)

        #expect(await http.lastRequest?.value(forHTTPHeaderField: "x-localis-resume-from") == nil)
    }

    @Test("duplicate frames at the replay boundary are dropped")
    func resumeDedupesBySeq() async throws {
        // SC-003 under disconnect: the bridge may resend frames the client
        // already has. Appending one twice duplicates text in the transcript.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"data: {"seq":41,"choices":[{"delta":{"content":"OLD"},"index":0}]}"# + "\n\n",
            #"data: {"seq":42,"choices":[{"delta":{"content":"SEEN"},"index":0}]}"# + "\n\n",
            #"data: {"seq":43,"choices":[{"delta":{"content":"new"},"index":0}]}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])

        let events = try await Self.collect(Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 42)).events)

        #expect(Self.text(events) == "new")
    }

    @Test("a gap in seq is accepted rather than stalling the turn")
    func resumeAcceptsGaps() async throws {
        // The bridge decides what to replay. A client demanding consecutive seq
        // would strand the turn forever the moment the bridge skipped one —
        // worse than a gap.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"data: {"seq":99,"choices":[{"delta":{"content":"later"},"index":0}]}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])

        let events = try await Self.collect(Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 42)).events)

        #expect(Self.text(events) == "later")
    }

    @Test("resumed content is byte-identical to an uninterrupted stream")
    func resumeMatchesUninterrupted() async throws {
        // The whole point of the cursor, stated as the property that matters.
        let frames = (0..<6).map { seq in
            #"data: {"seq":\#(seq),"choices":[{"delta":{"content":"\#(seq)"},"index":0}]}"# + "\n\n"
        }
        let whole = StubStreamingHTTP(responses: [.stream(
            status: 200, headers: [:], body: frames + ["data: [DONE]\n\n"]
        )])
        // Disconnect after seq 2, then resume: the bridge replays 2 as well.
        let resumed = StubStreamingHTTP(responses: [.stream(
            status: 200, headers: [:], body: Array(frames[2...]) + ["data: [DONE]\n\n"]
        )])

        let uninterrupted = try await Self.collect(Self.client(whole).send(Self.turn()).events)
        let firstHalf = "01"
        let secondHalf = Self.text(
            try await Self.collect(Self.client(resumed).resume(TurnCursor(turnID: "t-9", lastSeq: 2)).events)
        )

        #expect(Self.text(uninterrupted) == "012345")
        #expect(firstHalf + "2" + secondHalf == "012345")
    }

    @Test("a resume answered by a different turn is refused, not merged")
    func resumeRejectsAnotherTurn() async throws {
        // The failure this rules out: `seq` counts *per turn* (contract §3.3),
        // so another turn's frames carry numbers in exactly the same range. A
        // client that only compares `seq` would splice a second turn's text
        // into this one's transcript and advance this turn's cursor past
        // content it never received — SC-003 broken in both directions at once.
        //
        // Refused as a thrown error rather than by dropping the frames: a
        // stream that yields nothing and ends is indistinguishable from a turn
        // that finished, and the caller would mark the message complete.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200,
            headers: ["x-localis-turn-id": "t-OTHER"],
            body: [
                #"data: {"seq":43,"choices":[{"delta":{"content":"someone else's"},"index":0}]}"# + "\n\n",
                "data: [DONE]\n\n",
            ]
        )])

        await #expect(throws: LocalisError.malformedResponse) {
            _ = try await Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 42))
        }
    }

    @Test("a resume answered by the right turn still streams")
    func resumeAcceptsItsOwnTurn() async throws {
        // The other half of the check above, and not a formality: "refuse
        // everything" passes the mismatch test on its own, and a resume that
        // can never succeed is a worse bug than the one being fixed.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200,
            headers: ["x-localis-turn-id": "t-9"],
            body: [
                #"data: {"seq":43,"choices":[{"delta":{"content":"ours"},"index":0}]}"# + "\n\n",
                "data: [DONE]\n\n",
            ]
        )])

        let events = try await Self.collect(Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 42)).events)

        #expect(Self.text(events) == "ours")
    }

    @Test("a bridge that sends no turn id is trusted rather than refused")
    func resumeWithoutTurnIDHeader() async throws {
        // A bridge older than the resume contract omits the header — that is
        // why `TurnStream.turnID` is optional at all. Refusing on absence would
        // break resume against every such bridge, and the request was addressed
        // to `/v1/turns/t-9/resume`, so its routing already names the turn.
        // "Cannot confirm" is not the same claim as "confirmed wrong".
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200,
            headers: [:],
            body: [
                #"data: {"seq":43,"choices":[{"delta":{"content":"ok"},"index":0}]}"# + "\n\n",
                "data: [DONE]\n\n",
            ]
        )])

        let events = try await Self.collect(Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 42)).events)

        #expect(Self.text(events) == "ok")
    }

    @Test("an expired turn is retryable, not a dead end")
    func resumeExpired() async throws {
        let http = StubStreamingHTTP(responses: [
            .stream(status: 410, headers: [:], body: [#"{"error":{"code":"turn_expired"}}"#]),
        ])

        await #expect(throws: LocalisError.turnExpired) {
            _ = try await Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 1))
        }
    }

    @Test("resuming another device's turn is refused and leaks nothing")
    func resumeNotYours() async throws {
        let http = StubStreamingHTTP(responses: [
            .stream(status: 403, headers: [:], body: [
                #"{"error":{"code":"turn_not_yours","message":"/Users/someone/secret"}}"#,
            ]),
        ])

        do {
            _ = try await Self.client(http).resume(TurnCursor(turnID: "t-9", lastSeq: 1))
            Issue.record("expected a refusal")
        } catch {
            #expect(error as? LocalisError == .turnNotYours)
            // The bridge's diagnostic text may hold a path (constitution I). It
            // must not ride out on the error.
            #expect(String(describing: error).contains("secret") == false)
        }
    }

    @Test("an unknown turn is reported as such")
    func resumeUnknownTurn() async throws {
        let http = StubStreamingHTTP(responses: [
            .stream(status: 404, headers: [:], body: [#"{"error":{"code":"unknown_turn"}}"#]),
        ])

        await #expect(throws: LocalisError.unknownTurn) {
            _ = try await Self.client(http).resume(TurnCursor(turnID: "t-9"))
        }
    }

    // MARK: - Cancel (Amendment C §4)

    @Test("cancelling posts to the turn's cancel endpoint")
    func cancelPosts() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [])])

        try await Self.client(http).cancel(turnID: "t-9")

        let sent = try #require(await http.lastRequest)
        #expect(sent.url?.absoluteString == "https://mac.local:8443/v1/turns/t-9/cancel")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token")
    }

    @Test("a turn id cannot escape its path segment", arguments: [
        "../../v1/models",
        "t-9/cancel?x=1",
        "t 9",
    ])
    func turnIDIsEscaped(_ hostile: String) async throws {
        // `turn_id` is opaque and the contract requires it to be unpredictable,
        // so its bytes are whatever the bridge chose. Interpolated raw, a `/` or
        // a `..` would address a different endpoint than the one this method
        // names — and it would be the client, holding a valid bearer, making the
        // call.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [])])

        try await Self.client(http).cancel(turnID: hostile)

        let path = try #require(await http.lastRequest?.url?.absoluteString)
        #expect(path.hasPrefix("https://mac.local:8443/v1/turns/"))
        #expect(path.hasSuffix("/cancel"))
        // Exactly the three separators of `/v1/turns/{id}/cancel` — anything the
        // id contributed stayed inside its own segment.
        #expect(path.dropFirst("https://mac.local:8443".count).filter { $0 == "/" }.count == 4)
    }

    @Test("an ordinary turn id is not mangled into something unrecognisable")
    func ordinaryTurnIDUnescaped() async throws {
        // Escaping `-`, `.`, `_` and `~` is legal but pointless, and it turns a
        // readable id into `t%2D9` in the bridge's own request log — which is
        // where someone will be looking when this endpoint misbehaves.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [])])

        try await Self.client(http).cancel(turnID: "t-9_a.b~c")

        #expect(
            await http.lastRequest?.url?.absoluteString
                == "https://mac.local:8443/v1/turns/t-9_a.b~c/cancel"
        )
    }

    @Test("cancelling an already-finished turn is not an error")
    func cancelIsIdempotent() async throws {
        // Contract §4: 200 on a turn that already ended. The user pressing stop
        // as the last token lands must not produce an error.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [])])

        try await Self.client(http).cancel(turnID: "t-9")
    }

    @Test("cancelling a turn the host never had is reported, not swallowed")
    func cancelUnknownTurn() async throws {
        let http = StubStreamingHTTP(responses: [
            .stream(status: 404, headers: [:], body: [#"{"error":{"code":"unknown_turn"}}"#]),
        ])

        await #expect(throws: LocalisError.unknownTurn) {
            try await Self.client(http).cancel(turnID: "gone")
        }
    }

    // MARK: - Catalogues

    @Test("the backend list is fetched for this host alone")
    func modelsRequest() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"{"object":"list","x_localis":{"resumable_turns":true},"data":[{"id":"alpha"}]}"#,
        ])])

        let catalog = try await Self.client(http).models()

        #expect(await http.lastRequest?.url?.absoluteString == "https://mac.local:8443/v1/models")
        #expect(catalog.backends.map(\.id) == ["alpha"])
        #expect(catalog.host.resumableTurns)
    }

    @Test("the skill catalogue is fetched for this host alone")
    func skillsRequest() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [
            #"{"object":"list","data":[{"id":"to-spec","name":"To Spec","template":"T"}]}"#,
        ])])

        let skills = try await Self.client(http).skills()

        #expect(await http.lastRequest?.url?.absoluteString == "https://mac.local:8443/v1/skills")
        #expect(skills.map(\.id) == ["to-spec"])
    }

    // MARK: - Protocol negotiation (contract §0)

    @Test("a newer bridge asks the user to update the app")
    func negotiatesNewerBridge() async throws {
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200, headers: ["x-localis-protocol": "2"], body: [#"{"data":[]}"#]
        )])

        await #expect(throws: LocalisError.protocolUpgradeRequired(side: .app)) {
            _ = try await Self.client(http).models()
        }
    }

    @Test("an older bridge asks the user to update the Mac")
    func negotiatesOlderBridge() async throws {
        let http = StubStreamingHTTP(responses: [.stream(
            status: 200, headers: ["x-localis-protocol": "0"], body: [#"{"data":[]}"#]
        )])

        await #expect(throws: LocalisError.protocolUpgradeRequired(side: .bridge)) {
            _ = try await Self.client(http).models()
        }
    }

    @Test("a bridge that sends no protocol header is assumed compatible")
    func missingProtocolHeaderTolerated() async throws {
        // The header is the bridge's statement about itself. Treating silence as
        // incompatibility would lock the user out over a missing header.
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [#"{"data":[]}"#])])

        _ = try await Self.client(http).models()
    }

    @Test("a 426 names which side to upgrade", arguments: [
        ("2", LocalisError.protocolUpgradeRequired(side: .app)),
        ("0", LocalisError.protocolUpgradeRequired(side: .bridge)),
    ])
    func upgradeRequiredNamesSide(_ testCase: (header: String, expected: LocalisError)) async throws {
        // Contract §7. Sending the user to update the wrong end is worse than a
        // generic message: they do work that cannot help.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 426,
            headers: ["x-localis-protocol": testCase.header],
            body: [#"{"error":{"code":"protocol_upgrade_required"}}"#]
        )])

        await #expect(throws: testCase.expected) {
            _ = try await Self.client(http).models()
        }
    }

    // MARK: - Error mapping (contract §6)

    @Test("status and code map to the error the UI can act on", arguments: [
        (401, "invalid_token", LocalisError.unauthorized),
        (401, "token_revoked", LocalisError.tokenRevoked),
        (404, "unknown_model", LocalisError.unknownBackend),
        (404, "unknown_turn", LocalisError.unknownTurn),
        (409, "session_busy", LocalisError.sessionBusy),
        (410, "turn_expired", LocalisError.turnExpired),
        (403, "turn_not_yours", LocalisError.turnNotYours),
        (503, "backend_unavailable", LocalisError.backendUnavailable(reason: nil)),
    ])
    func mapsErrors(_ testCase: (status: Int, code: String, expected: LocalisError)) async throws {
        let http = StubStreamingHTTP(responses: [.stream(
            status: testCase.status, headers: [:], body: [#"{"error":{"code":"\#(testCase.code)"}}"#]
        )])

        await #expect(throws: testCase.expected) {
            _ = try await Self.client(http).models()
        }
    }

    @Test("token_revoked is distinct from a plain rejection")
    func revokedIsDistinct() async throws {
        // The two share a status code but demand opposite actions: one clears
        // the Keychain entry, the other must not. Collapsing them either throws
        // away a good token or leaves a dead one on the device forever.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 401, headers: [:], body: [#"{"error":{"code":"token_revoked"}}"#]
        )])

        do {
            _ = try await Self.client(http).models()
            Issue.record("expected a rejection")
        } catch {
            #expect(error as? LocalisError == .tokenRevoked)
            #expect(error as? LocalisError != .unauthorized)
        }
    }

    @Test("an unavailable backend keeps the host's reason code")
    func unavailableKeepsReason() async throws {
        let http = StubStreamingHTTP(responses: [.stream(
            status: 503, headers: [:],
            body: [#"{"error":{"code":"backend_unavailable","unavailable_reason":"not_logged_in"}}"#]
        )])

        await #expect(throws: LocalisError.backendUnavailable(reason: "not_logged_in")) {
            _ = try await Self.client(http).models()
        }
    }

    @Test("the bridge's diagnostic message never rides out on an error")
    func diagnosticMessageNotCarried() async throws {
        // Contract §6 and constitution I: `message` may contain absolute paths.
        // It is not carried inward at all — a field that does not exist cannot
        // be displayed by a caller who did not read the contract.
        let http = StubStreamingHTTP(responses: [.stream(
            status: 503, headers: [:],
            body: [#"{"error":{"code":"backend_unavailable","message":"/Users/tian/Projects/secret is missing"}}"#]
        )])

        do {
            _ = try await Self.client(http).models()
            Issue.record("expected a failure")
        } catch {
            let described = String(describing: error)
            #expect(described.contains("/Users") == false)
            #expect(described.contains("secret") == false)
        }
    }

    @Test("an unrecognised status is malformed rather than a guess")
    func unknownStatusIsMalformed() async throws {
        let http = StubStreamingHTTP(responses: [.stream(status: 418, headers: [:], body: ["{}"])])

        await #expect(throws: LocalisError.malformedResponse) {
            _ = try await Self.client(http).models()
        }
    }

    @Test("a socket failure is unreachable, never a bad response")
    func transportFailureIsUnreachable() async throws {
        let http = StubStreamingHTTP(responses: [.failure(URLError(.cannotConnectToHost))])

        await #expect(throws: LocalisError.unreachable) {
            _ = try await Self.client(http).models()
        }
    }

    @Test("a failure mid-stream surfaces as a lost connection, not as a crash")
    func midStreamFailure() async throws {
        let http = StubStreamingHTTP(responses: [.streamThenFail(
            status: 200,
            body: [#"data: {"seq":0,"choices":[{"delta":{"content":"partial"},"index":0}]}"# + "\n\n"],
            error: URLError(.networkConnectionLost)
        )])

        var received: [SequencedEvent] = []
        var thrown: (any Error)?
        do {
            for try await event in try await Self.client(http).send(Self.turn()).events { received.append(event) }
        } catch {
            thrown = error
        }

        #expect(Self.text(received) == "partial")
        #expect(thrown as? LocalisError == .connectionLost)
    }

    // MARK: - Per-host isolation (FR-028, Amendment A)
    //
    // The mechanical half of this rule lives in `ArchitectureTests`, which
    // already walks every source file for backend names and for a client that
    // could address a collection of hosts. Keeping those sweeps in one suite is
    // what stops a second, near-identical one from quietly falling behind.
}
