// MARK: - RemoteClientTests
//
// Go's client against a fake Mac on a real socket.
//
// The fake is the REAL `RemoteHandshake.Responder` behind a loopback
// `NWListener` — the same code the desktop runs — so a pass here means the phone
// and the Mac agree on every handshake byte, not merely that the client agrees
// with a mock of itself. What each test pins is a way the client used to fail,
// or would fail if the ordering discipline in `RemoteClient` were loosened.

import CryptoKit
import Network
import ShiftoverProtocol
import XCTest
@testable import ShiftoverClient

@MainActor
final class RemoteClientTests: XCTestCase {

    private func client() -> RemoteClient {
        RemoteClient(identity: RemoteIdentityKey(), deviceID: UUID(), deviceName: "Test iPhone")
    }

    private func endpoint(_ mac: FakeMac) -> RemoteEndpoint {
        RemoteEndpoint(host: "127.0.0.1", port: mac.port)
    }

    func testHandshakeCompletesAndCapabilitiesArriveSealed() async throws {
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        try await client.connect(to: endpoint(mac), pairingCode: nil,
                                 knownMacPublicKey: mac.identity.publicKeyData)
        XCTAssertEqual(client.state, .connected(hostName: "Fake-Mac", capabilities: [.read, .write]))
        XCTAssertEqual(client.hostName, "Fake-Mac", "kept with the pairing so the Mac is listed by its own name")
        _ = try await client.listProjects()
        client.disconnect()
        XCTAssertNil(client.hostName)
    }

    func testLargeConversationKeepsLANConnectionAlive() async throws {
        try await checkLargeConversation(relayed: false)
    }

    func testLargeConversationKeepsRelayConnectionAlive() async throws {
        try await checkLargeConversation(relayed: true)
    }

    private func checkLargeConversation(relayed: Bool) async throws {
        let mac = try await FakeMac.start(relayed ? .relayLargeConversation : .largeConversation)
        defer { mac.stop() }
        let client = client()
        defer { client.disconnect() }
        if relayed {
            try await client.connect(viaRelay: route(mac), knownMacPublicKey: mac.identity.publicKeyData)
        } else {
            try await client.connect(to: endpoint(mac), pairingCode: nil,
                                     knownMacPublicKey: mac.identity.publicKeyData)
        }
        // More than URLSession's default 1 MB. Preserve the entire reply and
        // verify subsequent encrypted traffic still uses the same connection.
        for _ in 0..<2 {
            let page = try await client.conversationMessages(conversationID: UUID(), limit: 400)
            XCTAssertEqual(page.messages.first?.text, FakeMac.largeReply)
            _ = try await client.listProjects()
        }
        XCTAssertEqual(mac.requestsHandled, 4)
        XCTAssertEqual(mac.framesThatFailedToOpen, 0)
        XCTAssertEqual(client.state, .connected(hostName: "Fake-Mac", capabilities: [.read, .write]))
    }

    func testConcurrentCallsAllGetAnswers() async throws {
        // Implicit nonces make send order load-bearing. Fire calls from many
        // tasks at once; if any two frames left in the opposite order to the
        // one they were sealed in, the Mac would drop one and its call would
        // hang — this would time out rather than pass.
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        try await client.connect(to: endpoint(mac), pairingCode: nil,
                                 knownMacPublicKey: mac.identity.publicKeyData)

        // A dropped frame leaves its call waiting forever. Disconnecting fails
        // every pending call, so the deadline turns a hang into a failure.
        let deadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(10))
            client.disconnect()
        }
        defer { deadline.cancel() }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask { @MainActor in _ = try await client.listProjects() }
                }
                try await group.waitForAll()
            }
        } catch {
            return XCTFail("calls went unanswered — frames left out of order? (\(error))")
        }
        XCTAssertEqual(mac.requestsHandled, 40)
        XCTAssertEqual(mac.framesThatFailedToOpen, 0)
        client.disconnect()
    }

    func testSilentMacTimesOutInsteadOfHangingForever() async throws {
        // The bound used to be a task-group race against `receive()`, which
        // cannot be cancelled — so it never fired while the socket stayed open.
        let mac = try await FakeMac.start(.silent)
        defer { mac.stop() }
        let client = client()
        client.handshakeTimeout = .milliseconds(300)

        let started = ContinuousClock.now
        do {
            try await client.connect(to: endpoint(mac), pairingCode: nil,
                                     knownMacPublicKey: mac.identity.publicKeyData)
            XCTFail("a Mac that never answers must not produce a session")
        } catch let error as RemoteClient.ClientError {
            XCTAssertTrue(error.userMessage.contains("didn't answer"), error.userMessage)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        guard case .failed = client.state else {
            return XCTFail("expected .failed, got \(client.state)")
        }
    }

    func testVersionRefusalIsTerminalAndSaysWhatToDo() async throws {
        let mac = try await FakeMac.start(.refuseVersion)
        defer { mac.stop() }
        let client = client()
        do {
            try await client.connect(to: endpoint(mac), pairingCode: nil,
                                     knownMacPublicKey: mac.identity.publicKeyData)
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(client.state, .refused(reason: "Shiftover Go is out of date."))
    }

    func testForgedAckIsRejected() async throws {
        // Whatever answered could not produce Noise message 2 for the key this
        // phone paired with. The client must refuse, never fall back.
        let mac = try await FakeMac.start(.forgeAck)
        defer { mac.stop() }
        let client = client()
        do {
            try await client.connect(to: endpoint(mac), pairingCode: nil,
                                     knownMacPublicKey: mac.identity.publicKeyData)
            XCTFail("a forged ack produced a session")
        } catch let error as RemoteClient.ClientError {
            XCTAssertTrue(error.userMessage.contains("isn't the Mac"), error.userMessage)
        }
    }

    func testTimedOutWriteIsNotReplayedAndSilenceIsProbedSeparately() async throws {
        let mac = try await FakeMac.start(.acceptThenSilent)
        defer { mac.stop() }
        let client = client()
        client.requestTimeout = .milliseconds(100)
        try await client.connect(to: endpoint(mac), pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        do {
            _ = try await client.call(.replyToAgent(worktreeID: UUID(), text: "one attempt"))
            XCTFail("silent RPC must time out")
        } catch {}
        XCTAssertEqual(mac.writeRequestsHandled, 1)
        guard case .connected = client.state else { return XCTFail("one slow request closed the socket") }
        let responsive = await client.isResponsive(within: .milliseconds(100))
        XCTAssertFalse(responsive)
        guard case .failed = client.state else { return XCTFail("fully silent socket stayed connected") }
        XCTAssertEqual(mac.writeRequestsHandled, 1, "a timed-out write must never be replayed")
    }

    func testSlowGitSummaryDoesNotDisconnectOtherRequestsOrHealthCheck() async throws {
        let mac = try await FakeMac.start(.slowSummary)
        defer { mac.stop() }
        let client = client()
        defer { client.disconnect() }
        client.requestTimeout = .milliseconds(80)
        try await client.connect(to: endpoint(mac), pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        do {
            _ = try await client.fleetSummary()
            XCTFail("slow summary must time out independently")
        } catch {}
        _ = try await client.listProjects()
        let responsive = await client.isResponsive(within: .milliseconds(80))
        XCTAssertTrue(responsive)
        // The late response must be decrypted and ignored, not break the
        // encrypted stream or complete an already-failed continuation twice.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await client.listProjects()
        XCTAssertEqual(client.state, .connected(hostName: "Fake-Mac", capabilities: [.read, .write]))
        XCTAssertEqual(mac.framesThatFailedToOpen, 0)
    }

    func testHealthProbeDoesNotWaitForGitSummary() async throws {
        let mac = try await FakeMac.start(.slowSummary)
        defer { mac.stop() }
        let client = client()
        defer { client.disconnect() }
        try await client.connect(to: endpoint(mac), pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        let responsive = await client.isResponsive(within: .milliseconds(80))
        XCTAssertTrue(responsive, "Git work must not determine whether the socket is alive")
        XCTAssertEqual(mac.requestsHandled, 1)
    }

    func testLiveTrafficKeepsConnectionWhenHealthReplyIsMissing() async throws {
        let mac = try await FakeMac.start(.silentProbeWithTraffic)
        defer { mac.stop() }
        let client = client()
        defer { client.disconnect() }
        try await client.connect(to: endpoint(mac), pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        let responsive = await client.isResponsive(within: .milliseconds(150))
        XCTAssertTrue(responsive)
        guard case .connected = client.state else { return XCTFail("live traffic was ignored") }
    }

    func testHealthProbeExpiresAndPublishesFailure() async throws {
        let mac = try await FakeMac.start(.acceptThenSilent)
        defer { mac.stop() }
        let client = client()
        try await client.connect(to: endpoint(mac), pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        let responsive = await client.isResponsive(within: .milliseconds(100))
        XCTAssertFalse(responsive)
        guard case .failed = client.state else { return XCTFail("health failure was not published") }
    }

    func testSuccessfulProbeDoesNotCloseSocketWhenItsDeadlinePasses() async throws {
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        try await client.connect(to: endpoint(mac), pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        let responsive = await client.isResponsive(within: .milliseconds(100))
        XCTAssertTrue(responsive)
        try await Task.sleep(for: .milliseconds(160))
        _ = try await client.listProjects()
        client.disconnect()
    }

    func testAutomaticRecoveryRehandshakesAfterLiveSocketDrops() async throws {
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        let endpoint = endpoint(mac)
        try await client.connect(to: endpoint, pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        await mac.dropConnection()
        let recovered = expectation(description: "reconnected")
        let recovery = ConnectionRecovery(healthyInterval: .seconds(60), retryDelay: { _ in .milliseconds(10) }) {
            if case .connected = client.state, await client.isResponsive(within: .milliseconds(100)) { return .healthy }
            do {
                try await client.connect(to: endpoint, pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
                recovered.fulfill()
                return .healthy
            } catch { return .retry }
        }
        recovery.start(immediately: true)
        await fulfillment(of: [recovered], timeout: 3)
        _ = try await client.listProjects()
        XCTAssertEqual(mac.framesThatFailedToOpen, 0)
        recovery.stop()
        client.disconnect()
    }

    // MARK: - Write gate

    private final class RefusingGate: WriteAuthorizing {
        var isUnlocked: Bool { false }
        var needsPasscode = false
        func authorize() async -> Bool { false }
        func noteDeviceAuthenticated() {}
        func lock() {}
    }

    /// Opening a session clears its badge on the Mac without asking for Face
    /// ID: it is looking, not acting, so a locked write gate does not stop it.
    func testOpeningASessionAcknowledgesItsStatusWithoutAWritePrompt() async throws {
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        client.writeGate = RefusingGate()
        try await client.connect(to: endpoint(mac), pairingCode: nil,
                                 knownMacPublicKey: mac.identity.publicKeyData)
        let worktree = UUID()
        _ = try await client.perform(.acknowledgeAgentStatus(worktreeID: worktree))
        XCTAssertEqual(mac.acknowledged, [worktree])
        XCTAssertEqual(mac.writeRequestsHandled, 0)
        client.disconnect()
    }

    func testAPhoneWithoutAPasscodeIsToldWhy() async throws {
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        let gate = RefusingGate()
        gate.needsPasscode = true
        client.writeGate = gate
        try await client.connect(to: endpoint(mac), pairingCode: nil,
                                 knownMacPublicKey: mac.identity.publicKeyData)
        do {
            try await client.perform(.interruptAgent(worktreeID: UUID()))
            XCTFail("a phone with no passcode acted on the Mac")
        } catch let error as RemoteClient.ClientError {
            XCTAssertEqual(error, .passcodeRequired)
            XCTAssertTrue(error.userMessage.contains("passcode"))
        }
        XCTAssertEqual(mac.writeRequestsHandled, 0)
        client.disconnect()
    }

    func testWritesWaitForTheDeviceOwner() async throws {
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        client.writeGate = RefusingGate()
        try await client.connect(to: endpoint(mac), pairingCode: nil,
                                 knownMacPublicKey: mac.identity.publicKeyData)

        // Reads are never gated.
        _ = try await client.listProjects()
        do {
            try await client.perform(.interruptAgent(worktreeID: UUID()))
            XCTFail("a write went out without the owner's confirmation")
        } catch let error as RemoteClient.ClientError {
            XCTAssertEqual(error, .notAuthorized)
        }
        XCTAssertFalse(client.sendTerminalInputNow(Data("y".utf8), paneID: UUID()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(mac.requestsHandled, 1, "only the read reached the Mac")
        XCTAssertTrue(mac.terminalBytes.isEmpty)
        client.disconnect()
    }

    func testFastTypingArrivesInOrder() async throws {
        // Keystrokes used to go out from one `Task` each, which Swift does not
        // run in creation order.
        let mac = try await FakeMac.start(.accept)
        defer { mac.stop() }
        let client = client()
        try await client.connect(to: endpoint(mac), pairingCode: nil,
                                 knownMacPublicKey: mac.identity.publicKeyData)
        let typed = "the quick brown fox jumps over the lazy dog 0123456789"
        let pane = UUID()
        for character in typed {
            XCTAssertTrue(client.sendTerminalInputNow(Data(String(character).utf8), paneID: pane))
        }
        for _ in 0..<100 where mac.terminalBytes.count < typed.utf8.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(String(decoding: mac.terminalBytes, as: UTF8.self), typed)
        XCTAssertEqual(mac.framesThatFailedToOpen, 0)
        client.disconnect()
    }

    // MARK: - Relay

    private func route(_ mac: FakeMac) -> RelayRoute {
        RelayRoute(url: "ws://127.0.0.1:\(mac.port)", token: RelayRoute.mintToken())
    }

    func testRelayConnectWaitsForTheMacThenHandshakes() async throws {
        let mac = try await FakeMac.start(.relayWithMac)
        defer { mac.stop() }
        let client = client()
        let route = route(mac)
        try await client.connect(viaRelay: route, knownMacPublicKey: mac.identity.publicKeyData)
        XCTAssertEqual(client.state, .connected(hostName: "Fake-Mac", capabilities: [.read, .write]))
        XCTAssertEqual(mac.routeHeader, route.token, "the token rides a header")
        XCTAssertEqual(client.relayRoute, FakeMac.handedRoute)
        _ = try await client.listProjects()
        client.disconnect()
    }

    func testFirstUseRelayInvitationCarriesProofBoundToTheHandshake() async throws {
        let mac = try await FakeMac.start(.relayWithMac)
        defer { mac.stop() }
        let client = client()
        let invitation = ShareInvitation(projectID: UUID(), projectName: "Project", hostName: "Host",
            address: "relay", port: 443, publicKey: mac.identity.publicKeyData)
        try await client.connect(viaRelay: route(mac), knownMacPublicKey: mac.identity.publicKeyData,
                                 pairingCode: invitation.pairingCode)
        defer { client.disconnect() }
        let hello = try XCTUnwrap(mac.incomingHello)
        XCTAssertEqual(hello.identity.pairingID, invitation.pairingID)
        let proof = try XCTUnwrap(hello.identity.pairingProof)
        XCTAssertTrue(RemotePairing.verifyPairingProof(proof, secret: invitation.secret,
            pairingID: invitation.pairingID, handshakeHash: hello.handshakeHash))
        XCTAssertFalse(RemotePairing.verifyPairingProof(proof, secret: Data(repeating: 0, count: 32),
            pairingID: invitation.pairingID, handshakeHash: hello.handshakeHash))
    }

    func testRelayWithoutTheMacSaysSoInsteadOfHanging() async throws {
        let mac = try await FakeMac.start(.relayWithoutMac)
        defer { mac.stop() }
        let client = client()
        client.macPresenceTimeout = .milliseconds(300)
        let started = ContinuousClock.now
        do {
            try await client.connect(viaRelay: route(mac),
                                     knownMacPublicKey: mac.identity.publicKeyData)
            XCTFail("no Mac on the relay must not produce a session")
        } catch let error as RemoteClient.ClientError {
            XCTAssertEqual(error, .macUnreachable)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testMacLeavingEndsTheSessionWithAClearReason() async throws {
        let mac = try await FakeMac.start(.relayMacLeaves)
        defer { mac.stop() }
        let client = client()
        try await client.connect(viaRelay: route(mac), knownMacPublicKey: mac.identity.publicKeyData)
        for _ in 0..<100 {
            if case .failed = client.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.state, .failed(reason: RemoteClient.ClientError.macOffline.userMessage))
    }

    func testMacThatClosesOnHelloExplainsPairingIsGone() async throws {
        // How the Mac answers an unknown key: it hangs up, uniformly. The phone
        // should say what that almost always means.
        let mac = try await FakeMac.start(.closeOnHello)
        defer { mac.stop() }
        let client = client()
        do {
            try await client.connect(to: endpoint(mac), pairingCode: nil,
                                     knownMacPublicKey: mac.identity.publicKeyData)
            XCTFail("expected the connection to fail")
        } catch let error as RemoteClient.ClientError {
            XCTAssertTrue(error.userMessage.contains("Pair it again"), error.userMessage)
        }
    }
}

// MARK: - Fake Mac

/// A one-connection stand-in for the desktop, running the shared responder.
final class FakeMac: @unchecked Sendable {

    enum Behavior {
        /// Completes the handshake and answers every `listProjects`.
        case accept
        case largeConversation
        case relayLargeConversation
        case slowSummary
        case silentProbeWithTraffic
        case acceptThenSilent
        /// Reads the hello and never replies.
        case silent
        /// Answers the hello with a cleartext version refusal.
        case refuseVersion
        /// Answers with a `HelloAck` whose Noise message is garbage.
        case forgeAck
        /// Closes the socket on receiving the hello.
        case closeOnHello
        /// Plays the relay with the Mac present: announces `mac-online`, then
        /// accepts, handing over a relay route in the ack.
        case relayWithMac
        /// Plays the relay with no Mac: says nothing, ever.
        case relayWithoutMac
        /// Like `relayWithMac`, then announces `mac-offline` after the ack.
        case relayMacLeaves
        /// Checks presence as the desktop does: advertises `.presenceProof`,
        /// opens writes on a valid owner proof, accepts a lock-screen answer
        /// carrying its own unlocked proof, and refuses everything else.
        case presence
        /// As `presence`, but the first write after the first proof is refused
        /// as though the Mac's window had already closed.
        case presenceClosesEarly
    }

    static let largeReply = String(repeating: "Complete reply. ", count: 140_000)

    let identity = RemoteIdentityKey()
    private let behavior: Behavior
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-mac")
    private var connection: NWConnection?
    private var responder: RemoteHandshake.Responder?
    private var channel: RemoteChannel?

    // Touched only on `queue`, read by tests after the calls complete.
    private(set) var requestsHandled = 0
    private(set) var writeRequestsHandled = 0
    /// Worktrees the phone said it opened (`acknowledgeAgentStatus`).
    private(set) var acknowledged: [UUID] = []
    private(set) var framesThatFailedToOpen = 0
    /// Keystroke bytes received, in arrival order.
    private(set) var terminalBytes = Data()
    /// The route header the client sent, as the relay would see it.
    private(set) var routeHeader: String?
    /// The presence keys the hello carried.
    private(set) var incomingHello: RemoteHandshake.IncomingHello?
    private(set) var helloPresenceKeys: PresenceKeys?
    /// Owner proofs that verified.
    private(set) var presenceProofs = 0
    /// Lock-screen answers that verified on their own proof.
    private(set) var lockScreenAnswers = 0
    private var presenceWindowOpen = false
    private var lastPresenceCounter: UInt64 = 0
    private var refuseNextWrite = false
    private var checksPresence: Bool { behavior == .presence || behavior == .presenceClosesEarly }
    /// The route the ack hands over in the relay behaviours.
    static let handedRoute = RelayRoute(url: "wss://relay.test", token: RelayRoute.mintToken())

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private final class HeaderBox: @unchecked Sendable { var value: String? }
    private var headerBox: HeaderBox?

    private init(behavior: Behavior) throws {
        self.behavior = behavior
        let parameters = NWParameters(tls: nil, tcp: .init())
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let captured = HeaderBox()
        websocket.setClientRequestHandler(DispatchQueue(label: "fake-mac-headers")) { _, headers in
            captured.value = headers.first { $0.name.lowercased() == RelayRoute.headerName }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        headerBox = captured
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(_ behavior: Behavior) async throws -> FakeMac {
        let mac = try FakeMac(behavior: behavior)
        mac.listener.newConnectionHandler = { [weak mac] connection in mac?.adopt(connection) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The handler runs on `mac.queue` only, so a plain flag in a box is
            // enough to resume exactly once.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            mac.listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready, .failed, .cancelled:
                    once.done = true
                    continuation.resume()
                default:
                    break
                }
            }
            mac.listener.start(queue: mac.queue)
        }
        return mac
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    func dropConnection() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.connection?.cancel()
                self.connection = nil
                self.channel = nil
                continuation.resume()
            }
        }
    }

    private func adopt(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.routeHeader = self.headerBox?.value
            switch self.behavior {
            case .relayWithMac, .relayMacLeaves, .relayLargeConversation: self.sendText(RelayPresence.macOnline.rawValue)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func sendText(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "notice", metadata: [metadata])
        connection?.send(content: Data(text.utf8), contentContext: context,
                         isComplete: true, completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, error == nil else { return }
            if let content, let frame = Frame.decode(content) { self.handle(frame) }
            self.receive(on: connection)
        }
    }

    private func send(_ frame: Frame) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection?.send(content: frame.encoded(), contentContext: context,
                         isComplete: true, completion: .idempotent)
    }

    private func handle(_ frame: Frame) {
        switch frame.type {
        case .hello:
            handleHello(frame.payload)
        case .terminalInput:
            guard let channel else { return }
            guard let plaintext = try? channel.open(frame.payload),
                  let input = TerminalPayload.decode(plaintext) else {
                framesThatFailedToOpen += 1
                return
            }
            if checksPresence, !presenceWindowOpen { return }
            terminalBytes.append(input.bytes)
        case .request:
            guard let channel else { return }
            guard let plaintext = try? channel.open(frame.payload),
                  let request = try? JSONDecoder().decode(RPCRequest.self, from: plaintext)
            else {
                framesThatFailedToOpen += 1
                return
            }
            requestsHandled += 1
            if checksPresence, let refusal = presenceRefusal(request, channel: channel) {
                reply(RPCResponse(id: request.id, result: refusal), on: channel)
                return
            }
            if request.method.isWrite { writeRequestsHandled += 1 }
            if behavior == .acceptThenSilent { return }
            let result: RPCResult
            switch request.method {
            case .provePresence: result = .ok
            case .acknowledgeAgentStatus(let worktreeID):
                acknowledged.append(worktreeID)
                result = .ok
            case .fleetSummary: result = .fleetSummary(FleetSummaryDTO(queued: 0, working: 1, toReview: 0))
            case .conversationMessages(let id, _):
                let messages: [AgentMessageDTO]
                if behavior == .largeConversation || behavior == .relayLargeConversation {
                    messages = [AgentMessageDTO(id: "large", timestamp: Date(), role: .assistant,
                                                title: "Codex", text: Self.largeReply,
                                                expanded: nil, tokens: nil)]
                } else {
                    messages = []
                }
                result = .conversationMessages(ConversationMessagesDTO(
                    conversationID: id, messages: messages, hasOlder: false))
            default: result = .projects([])
            }
            let response = RPCResponse(id: request.id, result: result)
            if behavior == .silentProbeWithTraffic, case .listProjects = request.method {
                queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, let channel = self.channel,
                          let sealed = try? channel.seal(TerminalPayload(paneID: UUID(), bytes: Data("live".utf8)).encoded()) else { return }
                    self.send(Frame(type: .terminalData, payload: sealed))
                }
                return
            }
            if behavior == .slowSummary, case .fleetSummary = request.method {
                // Seal only when sending: nonce order must follow wire order.
                queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, let channel = self.channel,
                          let sealed = try? channel.seal(JSONEncoder().encode(response)) else { return }
                    self.send(Frame(type: .response, payload: sealed))
                }
                return
            }
            guard let sealed = try? channel.seal(JSONEncoder().encode(response)) else { return }
            send(Frame(type: .response, payload: sealed))
        default:
            break
        }
    }

    /// The desktop's presence rules, in miniature. `nil` lets the request on.
    private func presenceRefusal(_ request: RPCRequest, channel: RemoteChannel) -> RPCResult? {
        let hash = channel.handshakeHash
        if case .provePresence(let proof) = request.method {
            guard let keys = helloPresenceKeys, proof.level == .owner,
                  proof.counter > lastPresenceCounter,
                  PresenceProof.verify(proof, keys: keys, handshakeHash: hash) else {
                return .failure(RPCError(code: .unauthorized, message: "bad proof"))
            }
            lastPresenceCounter = proof.counter
            presenceProofs += 1
            presenceWindowOpen = true
            // Only after the first proof, so the client's second one sticks.
            refuseNextWrite = behavior == .presenceClosesEarly && presenceProofs == 1
            return nil
        }
        guard request.method.isWrite else { return nil }
        if presenceWindowOpen, refuseNextWrite {
            refuseNextWrite = false
            presenceWindowOpen = false
            return .failure(RPCError(code: .presenceRequired, message: "window closed"))
        }
        if presenceWindowOpen { return nil }
        if let keys = helloPresenceKeys, let proof = request.presence,
           let binding = PresenceProof.notificationBinding(for: request.method),
           proof.counter > lastPresenceCounter,
           PresenceProof.verify(proof, keys: keys, handshakeHash: hash, binding: binding) {
            lastPresenceCounter = proof.counter
            lockScreenAnswers += 1
            return nil
        }
        return .failure(RPCError(code: .presenceRequired, message: "prove presence"))
    }

    private func reply(_ response: RPCResponse, on channel: RemoteChannel) {
        guard let sealed = try? channel.seal(JSONEncoder().encode(response)) else { return }
        send(Frame(type: .response, payload: sealed))
    }

    private func handleHello(_ payload: Data) {
        switch behavior {
        case .silent:
            return
        case .closeOnHello:
            connection?.cancel()
        case .refuseVersion:
            let refusal = RPCResponse(id: UUID(), result: .failure(
                RPCError(code: .incompatibleVersion, message: "Shiftover Go is out of date.")))
            send(Frame(type: .response, payload: (try? JSONEncoder().encode(refusal)) ?? Data()))
        case .forgeAck:
            let ack = HelloAck(handshake: Data(repeating: 0x42, count: 64))
            send(Frame(type: .helloAck, payload: (try? JSONEncoder().encode(ack)) ?? Data()))
        case .relayWithoutMac:
            return
        case .accept, .acceptThenSilent, .slowSummary, .silentProbeWithTraffic, .relayWithMac, .relayMacLeaves, .largeConversation, .relayLargeConversation, .presence, .presenceClosesEarly:
            guard let hello = try? JSONDecoder().decode(Hello.self, from: payload) else { return }
            let responder = RemoteHandshake.Responder(identity: identity)
            let relayed = behavior == .relayWithMac || behavior == .relayMacLeaves || behavior == .relayLargeConversation
            guard let incoming = try? responder.open(hello),
                  let (ack, channel) = try? responder.accept(HelloAckPayload(
                      appVersion: "fake", hostName: "Fake-Mac",
                      capabilities: checksPresence ? [.read, .write, .presenceProof] : [.read, .write],
                      relay: relayed ? Self.handedRoute : nil))
            else { return }
            incomingHello = incoming
            helloPresenceKeys = incoming.identity.presenceKeys
            self.responder = responder
            self.channel = channel
            send(Frame(type: .helloAck, payload: (try? JSONEncoder().encode(ack)) ?? Data()))
            if behavior == .relayMacLeaves {
                queue.asyncAfter(deadline: .now() + 0.1) {
                    self.sendText(RelayPresence.macOffline.rawValue)
                }
            }
        }
    }
}
