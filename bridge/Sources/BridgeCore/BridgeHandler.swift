import Foundation

/// The bridge's request handler: routes, authenticates, dispatches.
///
/// **Authentication is decided by `Route.requiresAuthentication`**, not by a
/// per-case check. A new route is protected the moment it exists, and the
/// mistake this shape rules out — adding an endpoint and forgetting to guard it
/// — is the one that leaves CLI execution open to the LAN.
public actor BridgeHandler: BridgeHandling {
    private let catalog: BackendCatalog
    private let runners: [String: any TurnRunning]
    private let tokens: TokenStore
    private let coordinator: TurnCoordinator
    private let bridgeName: String
    private let bridgeID: String

    /// The pairing session, when one is open. nil most of the time: a bridge
    /// with a permanently open pairing window is a bridge anyone can join.
    private var pairing: PairingSession?

    public init(
        catalog: BackendCatalog,
        runners: [any TurnRunning],
        tokens: TokenStore,
        coordinator: TurnCoordinator,
        bridgeName: String,
        bridgeID: String
    ) {
        self.catalog = catalog
        self.runners = Dictionary(runners.map { ($0.backendID, $0) }, uniquingKeysWith: { first, _ in first })
        self.tokens = tokens
        self.coordinator = coordinator
        self.bridgeName = bridgeName
        self.bridgeID = bridgeID
    }

    /// Opens a pairing window and returns the code to display.
    public func openPairing() -> String {
        let code = PairingSession.generateCode()
        pairing = PairingSession(code: code, bridgeName: bridgeName, bridgeID: bridgeID)
        return code
    }

    public func respond(to request: BridgeRequest) async -> BridgeResponse {
        let route = request.route

        // Auth first, before any handler runs. Checking inside each case would
        // make an unguarded case a silent hole rather than a compile error.
        //
        // **`invalid_token`, not `unauthorized`.** The code is not free text —
        // the client switches on it (§6) and maps anything unrecognised to
        // "malformed response", whose message tells the user the bridge is
        // broken. `unauthorized` reads perfectly sensibly here and is wrong for
        // exactly that reason: the phone would report a protocol fault instead
        // of "re-pair with this Mac", which is the one thing that fixes it.
        var device: TokenStore.Grant?
        if route.requiresAuthentication {
            guard let token = request.bearerToken,
                  let grant = await tokens.grant(for: token) else {
                return .error(status: 401, code: "invalid_token")
            }
            device = grant
        }

        switch route {
        case .pair:
            return await handlePair(request)

        case .models:
            return .json(status: 200, object: catalog.json)

        case .skills:
            // Amendment B cut skills to a client-side input accelerator, so
            // there is no catalog to serve — but the client still calls this,
            // and a 404 reaches it as an unparseable body rather than as
            // "none". An empty list is the honest answer.
            return .json(status: 200, object: ["object": "list", "data": [String]()])

        case .chatCompletions:
            return await handleChatCompletions(request, device: device)

        case .cancelTurn(let id):
            return await handleCancel(turnID: id, device: device)

        case .resumeTurn:
            // Declared unsupported rather than faked. `resumable_turns` is
            // false in the catalog, so a client that honours §2.1 never calls
            // this; one that calls anyway gets a code it can map, not a turn
            // that silently restarts from the beginning.
            return .error(status: 404, code: "unknown_turn")

        case .methodNotAllowed:
            return .error(status: 405, code: "method_not_allowed")

        case .notFound:
            return .error(status: 404, code: "not_found")
        }
    }

    // MARK: - Pairing

    private func handlePair(_ request: BridgeRequest) async -> BridgeResponse {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(request.body)),
            let frame = object as? [String: Any],
            let code = frame["code"] as? String
        else {
            return .error(status: 400, code: "invalid_request")
        }

        guard let session = pairing else {
            // No window open. Answered as 429 like any other dead session: the
            // user's remedy is the same — go to the Mac and start pairing.
            return .error(status: 429, code: "pairing_session_expired")
        }

        switch await session.submit(code: code) {
        case .paired(let token, let name, let id):
            pairing = nil
            await tokens.issue(
                token: token,
                to: TokenStore.Grant(
                    deviceName: frame["device_name"] as? String ?? "",
                    deviceID: frame["device_id"] as? String ?? ""
                )
            )
            return .json(status: 200, object: [
                "token": token,
                "bridge_name": name,
                "bridge_id": id,
                "protocol": BridgeProtocol.version,
            ])

        case .rejected:
            return .error(status: 401, code: "pairing_code_rejected")

        case .sessionExpired:
            pairing = nil
            return .error(status: 429, code: "pairing_session_expired")
        }
    }

    // MARK: - Turns

    private func handleChatCompletions(
        _ request: BridgeRequest,
        device: TokenStore.Grant?
    ) async -> BridgeResponse {
        guard let device else { return .error(status: 401, code: "invalid_token") }

        guard let turn = TurnRequest.decode(
            body: request.body,
            sessionID: request.header("x-localis-session-id"),
            workspace: request.header("x-localis-workspace")
        ) else {
            return .error(status: 400, code: "invalid_request")
        }

        // Unknown backend and unavailable backend are different answers: 404
        // means "this host has no such thing", 503 means "it exists and is not
        // usable right now" — the second is worth retrying, the first is not.
        guard let descriptor = catalog.backend(id: turn.backendID) else {
            return .error(status: 404, code: "unknown_backend")
        }
        guard descriptor.available, let runner = runners[turn.backendID] else {
            return .error(status: 503, code: "backend_unavailable")
        }

        let started = await coordinator.start(turn, on: runner, deviceID: device.deviceID)

        return .stream(
            status: 200,
            headers: ["x-localis-turn-id": started.turnID],
            events: started.events
        )
    }

    private func handleCancel(turnID: String, device: TokenStore.Grant?) async -> BridgeResponse {
        guard let device else { return .error(status: 401, code: "invalid_token") }

        switch await coordinator.cancel(turnID: turnID, deviceID: device.deviceID) {
        case .cancelled:
            return .json(status: 200, object: ["cancelled": true])
        case .unknownTurn:
            return .error(status: 404, code: "unknown_turn")
        case .notYours:
            return .error(status: 403, code: "turn_not_yours")
        }
    }
}
