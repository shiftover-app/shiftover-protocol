// MARK: - RemoteClient
//
// Go's half of the protocol. The mirror image of the desktop's
// `AppState+Remote`: connect, handshake, seal, dispatch, receive.
//
// ── Contract with the desktop ───────────────────────────────────────────
//
//   • `hello` / `helloAck` carry the two Noise IK handshake messages
//     (`RemoteHandshake`, shared with the desktop). Only the protocol version
//     is readable in them; the phone's identity is encrypted to the Mac's key.
//   • EVERYTHING after that is sealed by the resulting `RemoteChannel`. There
//     is exactly one send in this file that bypasses it, and it is the hello.
//   • The channel's nonces are implicit and position-bound, so frames must
//     leave in the order they were sealed. Every seal is therefore followed,
//     synchronously and on the main actor, by `enqueue` — never by a send
//     spawned into its own `Task`, whose start order Swift does not promise.
//   • Unknown frame types are SKIPPED, never fatal (D16), so a newer Mac can
//     introduce one without breaking this build.
//   • The Mac owns the terminal geometry. This client renders at whatever it
//     is told and never renegotiates.

import Foundation
import ShiftoverProtocol

@MainActor
public protocol RemoteClientDelegate: AnyObject {
    func remoteClient(_ client: RemoteClient, didReceive event: ServerEvent)
    func remoteClient(_ client: RemoteClient, didReceiveTerminalData data: Data, paneID: UUID)
    func remoteClient(_ client: RemoteClient, didReceiveBrowserFrame frame: BrowserFrame)
    func remoteClient(_ client: RemoteClient, didChangeState state: RemoteClient.State)
}

@MainActor
public extension RemoteClientDelegate {
    func remoteClient(_ client: RemoteClient, didReceiveBrowserFrame frame: BrowserFrame) {}
}

@MainActor
public final class RemoteClient: NSObject {

    public enum State: Equatable {
        case disconnected
        case connecting
        /// Socket open, handshake complete.
        case connected(hostName: String, capabilities: Set<Capability>)
        /// Terminal, and worth distinguishing from a transient drop: the user
        /// must *do* something (update an app, re-pair) rather than wait.
        case refused(reason: String)
        case failed(reason: String)

        /// Handshake complete and the socket still open.
        public var isOpen: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            delegate?.remoteClient(self, didChangeState: state)
        }
    }

    public weak var delegate: RemoteClientDelegate?
    /// Optional pane consumer; acknowledge only after accepting/rendering the frame.
    public var onBrowserFrame: ((BrowserFrame) -> Void)?

    private let identity: RemoteIdentityKey
    private let deviceID: UUID
    private let deviceName: String

    // URLSession defaults to 1 MB, which disconnects otherwise healthy
    // sessions when a full conversation page (or file preview) arrives.
    // Apply the same finite budget before resuming either transport.
    private static let maximumIncomingMessageBytes = 16 * 1024 * 1024

    private var lastAuthenticatedFrameAt: ContinuousClock.Instant?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!

    /// The Noise session. `nil` until the handshake completes.
    private var channel: RemoteChannel?

    /// Where the Mac says it can be reached off the local network, from the
    /// last completed handshake. The caller persists it with the pairing.
    public private(set) var relayRoute: RelayRoute?

    /// The name the Mac gave in its `helloAck`; `nil` while not connected.
    public var confirmationCode: String? {
        channel.map { ShareInvitation.confirmationCode(handshakeHash: $0.handshakeHash) }
    }

    public var hostName: String? {
        if case .connected(let name, _) = state { return name }
        return nil
    }

    /// Asked before every write (`RPCMethod.isWrite`). `nil` lets writes
    /// through — only for tests; the app always sets one.
    public var writeGate: WriteAuthorizing?

    /// Signs the presence proofs a Mac that advertises `.presenceProof` checks
    /// before every write (`PresenceKeys`). `nil` sends no keys, so such a Mac
    /// keeps this phone read-only.
    public var presence: PresenceSigning?
    /// Whether the connected Mac checks presence itself.
    private var macRequiresPresence = false
    /// Strictly increasing per connection, shared by both proof levels.
    private var presenceCounter: UInt64 = 0
    /// Until when the Mac holds writes open on this connection, a little
    /// short of its own window so a write never lands just after it closed.
    private var presenceOpenUntil: ContinuousClock.Instant?
    /// An owner proof on its way, so concurrent writes share one.
    private var presenceInFlight: Task<Void, Error>?

    /// How long to wait, on the relay, for the Mac to be announced present.
    /// The relay tells a newcomer at once when its peer is already there, so a
    /// wait longer than a round trip means the Mac is not.
    public var macPresenceTimeout: Duration = .seconds(6)

    /// Set by the handshake watchdog, so the failure it causes (a cancelled
    /// socket) can be reported as the timeout it really is.
    private var handshakeTimedOut = false

    /// In-flight RPCs, keyed by request id. Continuations rather than callbacks
    /// so calls read as `let projects = try await client.listProjects()`.
    private var pending: [UUID: CheckedContinuation<RPCResult, Error>] = [:]

    /// The Mac's public key for the host we are talking to. Needed to derive
    /// session keys, and — on a return connection — proof we have met before.
    private var macPublicKey: Data?

    public init(identity: RemoteIdentityKey, deviceID: UUID, deviceName: String) {
        self.identity = identity
        self.deviceID = deviceID
        self.deviceName = deviceName
        super.init()
        // Ephemeral: no cookies, no credential store. Nothing about this
        // connection should outlive it.
        session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: nil)
    }

    /// Payload bytes only, for measuring an actual terminal session over LAN
    /// or relay. Does not include framing, encryption, or WebSocket overhead.
    public private(set) var receivedTerminalBytes: Int = 0

    public enum ClientError: Error, Equatable {
        case notConnected
        case handshakeFailed(String)
        case unexpectedResult
        case transport(String)
        /// The relay reported the Mac gone — asleep, offline, or quit.
        case macOffline
        /// The user did not confirm it was them (Face ID / passcode) for a write.
        case notAuthorized
        /// This phone has no passcode, so writes are refused outright.
        case passcodeRequired
        /// The Mac checks Face ID itself, and this phone has no key it can
        /// prove it with — no passcode, or the key was reset since pairing.
        case presenceUnavailable
        /// Reached the relay, but the Mac is not connected to it.
        case macUnreachable
        /// The desktop answered with a structured refusal.
        ///
        /// Carries the CODE, not just the message, because the caller has to
        /// tell "this Mac is too old for that verb" apart from "that failed" —
        /// version skew is a permanent operating condition (D16), and the two
        /// deserve completely different handling.
        case refused(RPCErrorCode, String)

        /// What to show a person.
        ///
        /// It lives on the error rather than in the view layer because the
        /// client itself now needs it too — a failed connect has to record a
        /// reason in `State.failed`, and two copies of this switch in two files
        /// would drift the moment a case is added.
        public var userMessage: String {
            switch self {
            case .notConnected:            return "Not connected."
            case .macOffline:              return "Your Mac went offline. It may be asleep."
            case .notAuthorized:           return "Confirm it's you to act on your Mac."
            case .passcodeRequired:
                return "Set a passcode on this iPhone to act on your Mac. Without one, anyone holding it could."
            case .presenceUnavailable:
                return "This iPhone can't confirm it's you to your Mac. Make sure it has a passcode, then pair it again from Shiftover → Settings → Remote."
            case .macUnreachable:
                return "Your Mac isn't reachable right now — it may be asleep or offline."
            case .handshakeFailed(let m):  return m
            case .transport(let m):        return m
            case .unexpectedResult:        return "The Mac sent something unexpected."
            case .refused(_, let m):       return m
            }
        }
    }

    // MARK: - Connection

    /// How long to wait for the Mac's `helloAck`.
    ///
    /// There must be a bound: an unbounded `receive()` waits forever on a
    /// connection that is never coming back, and the UI sits on "Connecting…"
    /// with nothing to report. Ten seconds is far past a LAN round trip — or a
    /// relay one — and well inside a user's patience. Settable so a test can
    /// prove the bound holds without waiting ten seconds for it.
    public var handshakeTimeout: Duration = .seconds(10)
    public var requestTimeout: Duration = .seconds(20)

    /// Authentication/refusal failures need user action, not transport retries.
    public static func canRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? ClientError {
            switch error {
            case .notConnected, .transport, .macOffline, .macUnreachable: return true
            case .handshakeFailed, .unexpectedResult, .notAuthorized, .passcodeRequired,
                 .presenceUnavailable, .refused: return false
            }
        }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                    .dataNotAllowed].contains(error.code)
        }
        return false
    }

    /// Opens a socket and completes the handshake.
    ///
    /// - Parameter code: a freshly scanned pairing code on first connection;
    ///   `nil` when reconnecting to a Mac already paired with.
    public func connect(
        to endpoint: RemoteEndpoint,
        pairingCode code: RemotePairing.Code?,
        knownMacPublicKey: Data?
    ) async throws {
        closeSocket()
        state = .connecting
        do {
            try await openAndHandshake(endpoint: endpoint, code: code,
                                       knownMacPublicKey: knownMacPublicKey)
        } catch {
            // EVERY throwing path has to leave `.connecting`, or the UI latches
            // on a spinner it can never exit. This used to be the outcome of a
            // failed pairing: the error propagated, the view was told nothing,
            // and the only way out was to force-quit the app.
            //
            // `.refused` is preserved rather than overwritten — it is a
            // terminal, actionable state ("update the other side") that the
            // handshake has already diagnosed more precisely than this can.
            if case .refused = state {} else {
                state = .failed(reason: Self.message(for: error))
            }
            closeSocket()
            throw error
        }
        receiveLoop()
    }

    /// Opens a socket to the relay and completes the handshake through it.
    ///
    /// The relay admits the socket by the route token (sent as a header, never
    /// in the URL) and announces whether the Mac is there. The handshake that
    /// follows is exactly the LAN one: the relay only forwards ciphertext.
    public func connect(viaRelay route: RelayRoute, knownMacPublicKey: Data, pairingCode: RemotePairing.Code? = nil) async throws {
        closeSocket()
        state = .connecting
        do {
            guard let url = route.connectURL(role: .phone) else {
                throw ClientError.transport("The relay address this Mac gave is not usable.")
            }
            macPublicKey = knownMacPublicKey
            var request = URLRequest(url: url)
            request.setValue(route.token, forHTTPHeaderField: RelayRoute.headerName)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = Self.maximumIncomingMessageBytes
            self.task = task
            task.resume()

            try await awaitMacPresence()
            try await performHandshake(code: pairingCode)
        } catch {
            if case .refused = state {} else {
                state = .failed(reason: Self.message(for: error))
            }
            closeSocket()
            throw error
        }
        receiveLoop()
    }

    /// Waits for the relay's `mac-online`. Same watchdog shape as the
    /// handshake: closing the socket is the only thing that ends a pending
    /// `receive()`.
    private func awaitMacPresence() async throws {
        handshakeTimedOut = false
        let timeout = macPresenceTimeout
        let watchdog = Task { @MainActor [weak self] in
            try await Task.sleep(for: timeout)
            self?.handshakeTimedOut = true
            self?.task?.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        guard let task else { throw ClientError.notConnected }
        do {
            while true {
                if case .string(let notice) = try await task.receive(),
                   notice == RelayPresence.macOnline.rawValue {
                    return
                }
            }
        } catch {
            if handshakeTimedOut { throw ClientError.macUnreachable }
            throw ClientError.transport("Couldn't reach the relay. Check your connection.")
        }
    }

    private func openAndHandshake(
        endpoint: RemoteEndpoint,
        code: RemotePairing.Code?,
        knownMacPublicKey: Data?
    ) async throws {
        guard let url = endpoint.webSocketURL() else {
            throw ClientError.transport("\(endpoint.host) is not an address this app can dial.")
        }

        // Resolve the key BEFORE opening a socket — there is no point dialling
        // a Mac we could not talk to anyway, and it keeps the failure path from
        // leaking a live connection.
        macPublicKey = code?.publicKey ?? knownMacPublicKey
        guard macPublicKey != nil else {
            throw ClientError.handshakeFailed("no key for this Mac — pair first")
        }

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumIncomingMessageBytes
        self.task = task
        task.resume()

        try await performHandshake(code: code)
    }

    public func disconnect() {
        closeSocket()
        state = .disconnected
    }

    /// Tears the socket down without asserting a state.
    ///
    /// Separate from `disconnect()` because a *failed* connect must end in
    /// `.failed`, not `.disconnected` — the reason is the only thing the user
    /// can act on, and `disconnect()` would erase it.
    private func closeSocket(error: Error = ClientError.notConnected) {
        let old = task
        task = nil
        channel = nil
        lastAuthenticatedFrameAt = nil
        macRequiresPresence = false
        presenceCounter = 0
        presenceOpenUntil = nil
        presenceInFlight = nil
        old?.cancel(with: .goingAway, reason: nil)
        failPending(error)
    }

    private func connectionFailed(_ error: Error) {
        closeSocket(error: error)
        state = .failed(reason: Self.message(for: error))
    }

    private static func message(for error: Error) -> String {
        (error as? ClientError)?.userMessage ?? error.localizedDescription
    }

    // MARK: - Handshake

    private func performHandshake(code: RemotePairing.Code?) async throws {
        guard let macKey = macPublicKey else {
            throw ClientError.handshakeFailed("no key for this Mac — pair first")
        }

        let initiator: RemoteHandshake.Initiator
        let hello: Hello
        do {
            initiator = try RemoteHandshake.Initiator(identity: identity, macPublicKey: macKey)
            hello = try initiator.hello(appVersion: Self.appVersion, deviceID: deviceID,
                                        deviceName: deviceName, redeeming: code,
                                        presenceKeys: presence?.presenceKeys())
        } catch {
            throw ClientError.handshakeFailed("This pairing code is for a different Mac.")
        }

        try await sendRaw(Frame(type: .hello, payload: JSONEncoder().encode(hello)))

        let reply: Frame
        do {
            reply = try await receiveHandshakeReply()
        } catch ClientError.macOffline {
            // On the relay path the Mac "hangs up" by leaving and coming back,
            // so the phone sees `mac-offline` — the same answer as a closed
            // LAN socket, and it means the same thing.
            throw ClientError.handshakeFailed(code == nil
                ? "This Mac no longer recognises this phone. Pair it again from Shiftover → Settings → Remote."
                : "The Mac didn't accept that code. Show a fresh one and scan again.")
        } catch let error as ClientError {
            throw error
        } catch {
            // The Mac answers an unauthorised hello by closing the socket —
            // uniformly, whatever the reason, so a prober learns nothing. From
            // here that reads as a transport error; say what it most likely
            // means instead.
            throw ClientError.handshakeFailed(code == nil
                ? "This Mac no longer recognises this phone. Pair it again from Shiftover → Settings → Remote."
                : "The Mac didn't accept that code. Show a fresh one and scan again.")
        }

        guard reply.type == .helloAck else {
            // A version refusal arrives as a cleartext `.response` — it has to,
            // since a version mismatch means we may not share a handshake.
            if reply.type == .response,
               let response = try? JSONDecoder().decode(RPCResponse.self, from: reply.payload),
               case .failure(let error) = response.result {
                state = .refused(reason: error.message)
                throw ClientError.handshakeFailed(error.message)
            }
            throw ClientError.handshakeFailed("unexpected reply to hello")
        }

        let ack: HelloAckPayload
        do {
            let decoded = try JSONDecoder().decode(HelloAck.self, from: reply.payload)
            (ack, channel) = try initiator.finish(decoded)
            relayRoute = ack.relay
            macRequiresPresence = ack.capabilities.contains(.presenceProof)
        } catch RemoteHandshakeError.incompatible(let compatibility) {
            let message = compatibility.refusalMessage(localSideIsPhone: true)
                ?? "This Mac speaks a different protocol version."
            state = .refused(reason: message)
            throw ClientError.handshakeFailed(message)
        } catch {
            // Message 2 would not open: whatever answered does not hold the key
            // this phone paired with. Refuse — never fall back to talking to it.
            throw ClientError.handshakeFailed(
                "Something answered that isn't the Mac this phone paired with.")
        }

        state = .connected(hostName: ack.hostName, capabilities: ack.capabilities)
    }

    /// The first frame back, or a timeout.
    ///
    /// NOT a task-group race between `receive()` and a sleep. A group waits for
    /// every child before it exits and `URLSessionWebSocketTask.receive()` does
    /// not respond to cancellation, so such a race cannot time out while the
    /// socket stays open — the UI would sit on "Connecting…" for as long as the
    /// other end chose to say nothing. Closing the socket is the only thing that
    /// ends a pending `receive()`, so the watchdog does exactly that.
    private func receiveHandshakeReply() async throws -> Frame {
        handshakeTimedOut = false
        let timeout = handshakeTimeout
        let watchdog = Task { @MainActor [weak self] in
            try await Task.sleep(for: timeout)
            self?.handshakeTimedOut = true
            self?.task?.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        do {
            return try await receiveRaw()
        } catch {
            if handshakeTimedOut {
                throw ClientError.transport(
                    "The Mac didn't answer. Check that Shiftover is running with "
                    + "Remote turned on, then try again.")
            }
            throw error
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - RPC

    public func call(_ method: RPCMethod) async throws -> RPCResult {
        try await call(method, timeout: nil)
    }

    /// A call that may wait longer than `requestTimeout` — for one the other
    /// side answers only once its user decides.
    public func call(_ method: RPCMethod, timeout explicitTimeout: Duration?) async throws -> RPCResult {
        guard channel != nil, let socket = task else { throw ClientError.notConnected }
        if method.isWrite {
            try await unlockWrites()
        }
        // Authorization may suspend across a disconnect. A pending write
        // belongs only to the channel on which the user initiated it.
        try Task.checkCancellation()
        guard task === socket, channel != nil else { throw ClientError.notConnected }
        let result = try await send(RPCRequest(method: method), on: socket, timeout: explicitTimeout)
        // The Mac's window closed before ours did (a clock that ran fast, a
        // sleep). It refused before acting, so proving again and resending
        // once cannot do the write twice.
        if method.isWrite, case .failure(let error) = result, error.code == .presenceRequired {
            presenceOpenUntil = nil
            try await provePresenceIfNeeded()
            guard task === socket, channel != nil else { throw ClientError.notConnected }
            return try await send(RPCRequest(method: method), on: socket, timeout: explicitTimeout)
        }
        return result
    }

    /// Asks the owner (once per window) and proves presence to the Mac, so
    /// writes can go out. The terminal calls this when a keystroke was held
    /// back by `sendTerminalInputNow`.
    public func unlockWrites() async throws {
        if let writeGate, !(await writeGate.authorize()) {
            throw writeGate.needsPasscode ? ClientError.passcodeRequired : ClientError.notAuthorized
        }
        try await provePresenceIfNeeded()
    }

    /// A lock-screen answer. iOS required the phone unlocked to run the action,
    /// and Face ID cannot be shown from there, so the answer carries the weaker
    /// unlocked proof, which the Mac accepts for exactly this answer and
    /// nothing else (`PresenceProof.notificationBinding`).
    public func answerFromNotification(_ method: RPCMethod) async throws {
        guard macRequiresPresence, let binding = PresenceProof.notificationBinding(for: method) else {
            try await perform(method)
            return
        }
        guard let channel, let socket = task else { throw ClientError.notConnected }
        let assertion = try signPresence(.unlocked, handshakeHash: channel.handshakeHash, binding: binding)
        // Signing and sending in one step on the main actor: counters must
        // reach the Mac in the order they were taken.
        let result = try await send(RPCRequest(method: method, presence: assertion),
                                    on: socket, timeout: nil)
        if case .failure(let error) = result {
            throw ClientError.refused(error.code, error.message)
        }
    }

    private var presenceWindowIsOpen: Bool {
        guard macRequiresPresence else { return true }
        guard let until = presenceOpenUntil else { return false }
        return ContinuousClock.now < until
    }

    private func provePresenceIfNeeded() async throws {
        guard !presenceWindowIsOpen else { return }
        if let inFlight = presenceInFlight {
            try await inFlight.value
            return
        }
        let proving = Task { @MainActor in try await self.proveOwnerPresence() }
        presenceInFlight = proving
        defer { if presenceInFlight == proving { presenceInFlight = nil } }
        try await proving.value
    }

    private func proveOwnerPresence() async throws {
        if let writeGate, !(await writeGate.authorizeForPresence()) {
            throw writeGate.needsPasscode ? ClientError.passcodeRequired : ClientError.notAuthorized
        }
        guard let channel, let socket = task else { throw ClientError.notConnected }
        let assertion = try signPresence(.owner, handshakeHash: channel.handshakeHash, binding: Data())
        let result = try await send(RPCRequest(method: .provePresence(assertion)),
                                    on: socket, timeout: nil)
        if case .failure(let error) = result {
            throw ClientError.refused(error.code, error.message)
        }
        presenceOpenUntil = .now + .seconds(PresenceProof.window - 30)
    }

    private func signPresence(_ level: PresenceLevel, handshakeHash: Data,
                              binding: Data) throws -> PresenceAssertion {
        guard let presence else { throw ClientError.presenceUnavailable }
        presenceCounter += 1
        let message = PresenceProof.message(level: level, counter: presenceCounter,
                                            handshakeHash: handshakeHash, binding: binding)
        do {
            let context = level == .owner ? writeGate?.authenticationContext : nil
            return PresenceAssertion(level: level, counter: presenceCounter,
                                     signature: try presence.sign(message, level: level, context: context))
        } catch {
            throw ClientError.presenceUnavailable
        }
    }

    /// Seals and sends one request, then waits for its response.
    private func send(_ request: RPCRequest, on socket: URLSessionWebSocketTask,
                      timeout explicitTimeout: Duration?) async throws -> RPCResult {
        let method = request.method
        let payload = try JSONEncoder().encode(request)
        let timeout: Duration
        if let explicitTimeout { timeout = explicitTimeout }
        else if case .gitMutate = method { timeout = max(requestTimeout, .seconds(90)) }
        else { timeout = requestTimeout }
        let watchdog = Task { @MainActor [weak self] in
            try await Task.sleep(for: timeout)
            guard let self, self.task === socket,
                  let continuation = self.pending.removeValue(forKey: request.id) else { return }
            // A slow Git/read operation is not evidence that the socket died.
            // Its late reply is still decrypted by handle(), maintaining nonce
            // order, but no longer has a caller to resume. Never replay writes.
            continuation.resume(throwing: ClientError.transport(method.isWrite
                ? "The Mac hasn't confirmed this action. Check its result before trying again."
                : "The Mac didn't answer this request in time. Try refreshing it."))
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            // Register BEFORE sending, so a fast response always finds its
            // waiter.
            pending[request.id] = continuation
            do {
                try sendSealed(.request, payload) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        // Resume here only if the receive loop has not already
                        // resumed it — a continuation resumed twice traps.
                        guard let self, self.task === socket, self.pending[request.id] != nil else { return }
                        self.connectionFailed(error)
                    }
                }
            } catch {
                pending.removeValue(forKey: request.id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Writes one keystroke's bytes to an attached pane's pty, **now**, in call
    /// order — for the terminal view, which gets keystrokes one at a time on
    /// the main thread.
    ///
    /// Synchronous on purpose. The view used to hand each keystroke to its own
    /// `Task`, and separately-created tasks do not promise to run in creation
    /// order, so fast typing could reach the Mac scrambled. Returns `false`
    /// (and sends nothing) while writes are locked; the caller asks to unlock.
    @discardableResult
    public func sendTerminalInputNow(_ bytes: Data, paneID: UUID) -> Bool {
        if let writeGate, !writeGate.isUnlocked { return false }
        // The Mac drops keystrokes outside its presence window, so hold them
        // back here and let the caller prove presence instead.
        if !presenceWindowIsOpen { return false }
        let payload = TerminalPayload(paneID: paneID, bytes: bytes).encoded()
        return (try? sendSealed(.terminalInput, payload, completion: { _ in })) != nil
    }

    /// Mac-to-Mac Drive uses a host-approved, connection-owned per-pane grant.
    /// The host enforces its five-minute idle and sixty-minute hard expiry.
    /// Call only from a surface enabled by driverChanged for this device; this
    /// method does not grant access and owner/phone paths retain their gates.
    @discardableResult
    public func sendSharedTerminalInputNow(_ bytes: Data, paneID: UUID) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 64 * 1024 else { return false }
        let payload = TerminalPayload(paneID: paneID, bytes: bytes).encoded()
        return (try? sendSealed(.terminalInput, payload, completion: { _ in })) != nil
    }

    /// Incoming authenticated traffic already proves the session is alive.
    /// When quiet, probe an in-memory read: fleetSummary performs Git review
    /// scans and must never be used as a network heartbeat.
    public func isResponsive(within timeout: Duration = .seconds(10)) async -> Bool {
        guard !Task.isCancelled, case .connected = state, let socket = task else { return false }
        let started = ContinuousClock.now
        if let lastAuthenticatedFrameAt, lastAuthenticatedFrameAt.duration(to: started) < timeout {
            return true
        }
        do {
            _ = try await call(.listProjects, timeout: timeout)
            return task === socket
        } catch {
            guard !Task.isCancelled, task === socket else { return false }
            // Other requests or live events can overtake a delayed probe.
            if let lastAuthenticatedFrameAt, lastAuthenticatedFrameAt >= started { return true }
            connectionFailed(ClientError.transport("The Mac stopped responding."))
            return false
        }
    }

    /// Writes bytes to an attached pane's pty.
    ///
    /// Byte-exact rather than string-based, so arrow keys, control sequences and
    /// anything non-UTF8 survive rather than being mangled.
    public func sendTerminalInput(_ bytes: Data, paneID: UUID) async throws {
        try await unlockWrites()
        let payload = TerminalPayload(paneID: paneID, bytes: bytes).encoded()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try sendSealed(.terminalInput, payload) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Seals one frame and hands it to the socket in the same synchronous step.
    ///
    /// This pairing is the ordering guarantee: the channel's nonces are
    /// position-bound, `URLSessionWebSocketTask` transmits in the order `send`
    /// is called, and nothing can run between the two lines below on the main
    /// actor. Split them — seal here, send from a `Task` — and two frames can
    /// leave in the opposite order, after which the Mac drops the second (it
    /// fails to open) and the first's RPC waits forever.
    private func sendSealed(_ type: FrameType, _ plaintext: Data,
                            completion: @escaping @Sendable (Error?) -> Void) throws {
        guard let channel, let task else { throw ClientError.notConnected }
        let sealed = try channel.seal(plaintext)
        task.send(.data(Frame(type: type, payload: sealed).encoded()), completionHandler: completion)
    }

    // MARK: - Receive

    private func receiveLoop() {
        guard let socket = task else { return }
        Task { [weak self] in
            while true {
                guard let self, self.task === socket else { return }
                do {
                    let frame = try await self.receiveRaw(from: socket)
                    guard self.task === socket else { return }
                    self.handle(frame)
                } catch {
                    // A cancelled task is an intentional disconnect, not a
                    // failure — surfacing it as one would show the user a scary
                    // error every time they backgrounded the app.
                    guard self.task === socket else { return }
                    self.connectionFailed(error)
                    return
                }
            }
        }
    }

    private func handle(_ frame: Frame) {
        guard let channel, let payload = try? channel.open(frame.payload) else {
            // A frame that will not open is tampering, corruption or a replay.
            // Dropping it is correct — replying would confirm we are live — and
            // it consumes no nonce, so the next authentic frame still opens.
            return
        }

        lastAuthenticatedFrameAt = .now
        switch frame.type {
        case .response:
            guard let response = try? JSONDecoder().decode(RPCResponse.self, from: payload),
                  let continuation = pending.removeValue(forKey: response.id)
            else { return }
            continuation.resume(returning: response.result)

        case .event:
            guard let event = try? JSONDecoder().decode(ServerEvent.self, from: payload) else {
                // An event this build does not know — skip it (D16). A newer
                // Mac must be able to add one without breaking us.
                return
            }
            delegate?.remoteClient(self, didReceive: event)

        case .browserFrame:
            guard case .connected(_, let capabilities) = state,
                  capabilities.contains(.browserStream),
                  let browser = BrowserFrame.decode(payload) else { return }
            delegate?.remoteClient(self, didReceiveBrowserFrame: browser)
            onBrowserFrame?(browser)

        case .terminalData:
            guard let terminal = TerminalPayload.decode(payload) else { return }
            receivedTerminalBytes += terminal.bytes.count
            delegate?.remoteClient(self, didReceiveTerminalData: terminal.bytes,
                                   paneID: terminal.paneID)

        case .hello, .helloAck, .request, .terminalInput:
            // Client→server only, or already handled during the handshake.
            break
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    // MARK: - Socket

    private func sendRaw(_ frame: Frame) async throws {
        guard let task else { throw ClientError.notConnected }
        try await task.send(.data(frame.encoded()))
    }

    private func receiveRaw(from source: URLSessionWebSocketTask? = nil) async throws -> Frame {
        guard let task = source ?? self.task else { throw ClientError.notConnected }
        switch try await task.receive() {
        case .data(let data):
            guard let frame = Frame.decode(data) else {
                // Unknown tag → skip and read the next one, rather than failing
                // the connection (D16).
                return try await receiveRaw(from: task)
            }
            return frame
        case .string(let notice):
            // The relay's bare-ASCII presence notices. Only one matters once a
            // session is up: the Mac leaving ends it — say so, rather than let
            // the next call time out against a peer that is gone.
            if notice == RelayPresence.macOffline.rawValue { throw ClientError.macOffline }
            return try await receiveRaw(from: task)
        @unknown default:
            throw ClientError.transport("unknown message kind")
        }
    }
}

// MARK: - Typed conveniences

extension RemoteClient {

    public func listProjects() async throws -> [ProjectDTO] {
        guard case .projects(let projects) = try await call(.listProjects) else {
            throw ClientError.unexpectedResult
        }
        return projects
    }

    public func listWorktrees(projectID: UUID? = nil) async throws -> [WorktreeDTO] {
        guard case .worktrees(let worktrees) =
                try await call(.listWorktrees(projectID: projectID)) else {
            throw ClientError.unexpectedResult
        }
        return worktrees
    }

    public func fleetSummary() async throws -> FleetSummaryDTO {
        guard case .fleetSummary(let summary) = try await call(.fleetSummary) else {
            throw ClientError.unexpectedResult
        }
        return summary
    }

    public func reviewItems() async throws -> [ReviewItemDTO] {
        guard case .reviewItems(let items) = try await call(.reviewItems) else {
            throw ClientError.unexpectedResult
        }
        return items
    }

    public func listConversations(projectID: UUID? = nil) async throws -> [ConversationDTO] {
        switch try await call(.listConversations(projectID: projectID)) {
        case .conversations(let conversations):
            return conversations
        case .failure(let error):
            // Not flattened to `.unexpectedResult`: a Mac that predates the
            // conversation verbs answers `.unsupportedMethod` here, and the
            // caller needs to recognise that specific case to degrade instead
            // of treating it as a fault.
            throw ClientError.refused(error.code, error.message)
        default:
            throw ClientError.unexpectedResult
        }
    }

    /// Fetches a conversation's messages **and** subscribes to its appends —
    /// the desktop fuses the two so a message landing between a separate fetch
    /// and subscribe cannot fall down the gap.
    public func conversationMessages(
        conversationID: UUID, limit: Int
    ) async throws -> ConversationMessagesDTO {
        switch try await call(.conversationMessages(
            conversationID: conversationID, limit: limit)) {
        case .conversationMessages(let page):
            return page
        case .failure(let error):
            throw ClientError.refused(error.code, error.message)
        default:
            throw ClientError.unexpectedResult
        }
    }

    /// Per-phone delivery and the latest actual Bluetooth observation.
    public func notificationPresence(mode: PhoneNotificationMode?, rssi: Int?, sampleID: UUID? = nil) async throws -> NotificationPresenceDTO {
        let result = try await call(.notificationPresence(mode: mode, rssi: rssi, sampleID: sampleID))
        switch result {
        case .notificationPresence(let value): return value
        case .failure(let error): throw ClientError.refused(error.code, error.message)
        default: throw ClientError.unexpectedResult
        }
    }

    /// This phone's preferences as the Mac holds them, replacing them first
    /// when `update` is set.
    public func phonePreferences(update: PhonePreferencesDTO? = nil) async throws -> PhonePreferencesStateDTO {
        switch try await call(.phonePreferences(update: update)) {
        case .phonePreferences(let value): return value
        case .failure(let error): throw ClientError.refused(error.code, error.message)
        default: throw ClientError.unexpectedResult
        }
    }

    /// Relative file suggestions scoped to a registered Mac worktree.
    public func worktreeFiles(worktreeID: UUID, query: String) async throws -> [String] {
        switch try await call(.listWorktreeFiles(worktreeID: worktreeID, query: query)) {
        case .worktreeFiles(let paths): return paths
        case .failure(let error):
            if error.code == .unsupportedMethod {
                throw ClientError.transport("Update Shiftover on your Mac to use file suggestions.")
            }
            throw ClientError.refused(error.code, error.message)
        default: throw ClientError.unexpectedResult
        }
    }

    /// The slash commands this worktree's agent will actually accept —
    /// built-ins plus the user's and the repo's own command files.
    ///
    /// `refused(.unsupportedMethod)` is a NORMAL outcome here, not a fault: it
    /// means the Mac predates this verb. The caller degrades to the bundled
    /// built-ins rather than showing nothing — see
    /// `ConversationModel.loadSlashCommands`.
    public func slashCommands(worktreeID: UUID,
                              agent: ConversationAgentDTO) async throws -> [SlashCommandDTO] {
        switch try await call(.listSlashCommands(worktreeID: worktreeID, agent: agent)) {
        case .slashCommands(let commands):
            return commands
        case .failure(let error):
            throw ClientError.refused(error.code, error.message)
        default:
            throw ClientError.unexpectedResult
        }
    }

    /// Reconciles the Mac's agent input box to `text` — the shared composer's
    /// outbound half.
    ///
    /// Distinguishes refusal from fault deliberately, because the caller acts
    /// on the difference: `.unsupportedMethod` means the Mac predates the verb
    /// and the composer should fall back to sending whole messages, while
    /// `.preconditionFailed` means there is no agent running and is worth
    /// showing only when the user pressed send.
    public func setAgentInput(worktreeID: UUID, text: String,
                              seq: UInt64, submit: Bool) async throws {
        switch try await call(.setAgentInput(worktreeID: worktreeID, text: text,
                                             seq: seq, submit: submit)) {
        case .ok:
            return
        case .failure(let error):
            throw ClientError.refused(error.code, error.message)
        default:
            throw ClientError.unexpectedResult
        }
    }

    /// Context / model / cost for the worktree's agent session. `nil` is an
    /// honest "no Claude or Codex session to read there".
    public func monitorSummary(worktreeID: UUID) async throws -> MonitorSummaryDTO? {
        guard case .monitorSummary(let summary) =
                try await call(.monitorSummary(worktreeID: worktreeID)) else {
            throw ClientError.unexpectedResult
        }
        return summary
    }

    public func panes(worktreeID: UUID) async throws -> [PaneDTO] {
        guard case .panes(let panes) = try await call(.listPanes(worktreeID: worktreeID)) else {
            throw ClientError.unexpectedResult
        }
        return panes
    }

    public func attachTerminal(paneID: UUID) async throws -> TerminalAttachment {
        switch try await call(.attachTerminal(paneID: paneID)) {
        case .terminalAttached(let attachment):
            return attachment
        case .failure(let error):
            throw ClientError.transport(error.message)
        default:
            throw ClientError.unexpectedResult
        }
    }

    /// Runs a mutating verb, surfacing the desktop's own message on refusal —
    /// including the read-only one, which is the most common and the most
    /// actionable ("Allow control in Settings → Remote").
    @discardableResult
    public func perform(_ method: RPCMethod) async throws -> Bool {
        if case .failure(let error) = try await call(method) {
            throw ClientError.transport(error.message)
        }
        return true
    }
}
