// MARK: - shiftover-probe
//
// A command-line stand-in for Shiftover Go. Pairs with a running Shiftover,
// runs the real handshake, and exercises the RPC surface over a real socket.
//
// This exists because unit tests prove the crypto is *correct* while proving
// nothing about whether the pieces are *connected*. The desktop's transport,
// handshake, pairing tag, frame sealing, RPC dispatch and DTO mapping have
// never run against each other end to end — this is what does that.
//
// It also doubles as the reference implementation for Go's client: whatever
// this file does, the iOS app must do.
//
//   USAGE
//     SHIFTOVER_PORT=56658 shiftover-probe pair "shiftover://pair?v=1&id=…"
//     shiftover-probe connect <host> <port>              # subsequent
//
//   `connect` also opens the busiest conversation and waits `SHIFTOVER_WAIT`
//   seconds (default 20) for a live append. That wait is the only check that
//   proves *streaming* rather than request/response: type at the agent while it
//   runs and the message should appear here unsolicited.
//
// Pairing state is kept in ./shiftover-probe-state.json — a throwaway, and
// deliberately not in the user's Application Support.

import Foundation
import ShiftoverProtocol

// MARK: - Persisted probe state

struct ProbeState: Codable {
    var privateKey: Data
    var deviceID: UUID
    /// The Mac's long-term key, from the QR. A returning connection cannot even
    /// start without it — Noise IK encrypts the very first message to it.
    var macPublicKey: Data
    var host: String
    var port: UInt16

    static let path = URL(fileURLWithPath: "shiftover-probe-state.json")

    static func load() -> ProbeState? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(ProbeState.self, from: data)
    }

    func save() {
        try? JSONEncoder().encode(self).write(to: Self.path)
    }
}

// MARK: - Output helpers

func info(_ message: String)  { print("   \(message)") }
func step(_ message: String)  { print("\n▸ \(message)") }
func ok(_ message: String)    { print("   ✅ \(message)") }
func fail(_ message: String) -> Never {
    print("\n❌ \(message)")
    exit(1)
}

// MARK: - The probe

final class Probe: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!

    private let identity: RemoteIdentityKey
    private let deviceID: UUID
    /// The session. `nil` until the handshake completes; every frame after it
    /// is sealed and opened here.
    private var channel: RemoteChannel?

    private let connected = DispatchSemaphore(value: 0)

    init(identity: RemoteIdentityKey, deviceID: UUID) {
        self.identity = identity
        self.deviceID = deviceID
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func connect(host: String, port: UInt16) throws {
        // `ws://`, deliberately: the Noise handshake inside the channel is what
        // secures it, on the LAN exactly as on the relay.
        guard let url = URL(string: "ws://\(host):\(port)") else {
            fail("bad host/port")
        }
        task = session.webSocketTask(with: url)
        task?.resume()

        guard connected.wait(timeout: .now() + 10) == .success else {
            fail("could not connect to \(host):\(port) — is Shiftover running with Remote enabled?")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        connected.signal()
    }

    // MARK: Frames

    private func sendRaw(_ frame: Frame) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        task?.send(.data(frame.encoded())) { error in
            sendError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        if let sendError { throw sendError }
    }

    private func receiveRaw(timeout: TimeInterval = 10) throws -> Frame {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URLSessionWebSocketTask.Message, Error>?
        task?.receive { r in
            result = r
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            // A bounded wait expiring is an ordinary outcome for the streaming
            // check, not a probe failure — the agent may simply be idle.
            throw ProbeTimeout()
        }
        switch result {
        case .success(.data(let data)):
            guard let frame = Frame.decode(data) else { fail("undecodable frame") }
            return frame
        case .success(.string(let s)):
            fail("unexpected text frame: \(s)")
        case .failure(let error):
            throw error
        default:
            fail("empty receive")
        }
    }

    /// Sends a sealed frame. Everything after the handshake goes through here.
    private func send<T: Encodable>(_ type: FrameType, _ value: T) throws {
        guard let channel else { fail("no session — handshake first") }
        let plaintext = try JSONEncoder().encode(value)
        try sendRaw(Frame(type: type, payload: try channel.seal(plaintext)))
    }

    private func receiveSealed(timeout: TimeInterval = 10) throws -> (FrameType, Data) {
        guard let channel else { fail("no session") }
        let frame = try receiveRaw(timeout: timeout)
        return (frame.type, try channel.open(frame.payload))
    }

    // MARK: Handshake

    /// Runs the handshake, optionally redeeming a pairing code. This is the
    /// sequence Go's `RemoteClient` must follow, step for step.
    func handshake(macPublicKey: Data, code: RemotePairing.Code?, deviceName: String) throws {
        let initiator: RemoteHandshake.Initiator
        do {
            initiator = try RemoteHandshake.Initiator(identity: identity, macPublicKey: macPublicKey)
        } catch {
            fail("bad Mac key: \(error)")
        }

        let hello = try initiator.hello(appVersion: "probe", deviceID: deviceID,
                                        deviceName: deviceName, redeeming: code)
        try sendRaw(Frame(type: .hello, payload: try JSONEncoder().encode(hello)))

        let reply: Frame
        do {
            reply = try receiveRaw()
        } catch {
            // The Mac answers an unauthorised hello by closing — uniformly, so
            // an unpaired prober learns only "no".
            fail("the Mac closed the connection — unpaired, expired code, or wrong Mac (\(error))")
        }
        guard reply.type == .helloAck else {
            // A version refusal arrives as an unsealed `.response`.
            if reply.type == .response,
               let response = try? JSONDecoder().decode(RPCResponse.self, from: reply.payload),
               case .failure(let error) = response.result {
                fail("refused: \(error.message)")
            }
            fail("expected helloAck, got \(reply.type)")
        }

        let ack = try JSONDecoder().decode(HelloAck.self, from: reply.payload)
        do {
            let (payload, channel) = try initiator.finish(ack)
            self.channel = channel
            ok("paired with \(payload.hostName) (Shiftover \(payload.appVersion))")
            info("capabilities: \(payload.capabilities.map(\.rawValue).sorted().joined(separator: ", "))")
        } catch {
            fail("handshake failed: \(error)")
        }
    }

    // MARK: RPC

    @discardableResult
    func call(_ method: RPCMethod, label: String) throws -> RPCResult {
        let request = RPCRequest(method: method)
        try send(.request, request)

        // Skip any server-push events that arrive while we wait.
        for _ in 0..<10 {
            let (type, payload) = try receiveSealed()
            if type == .event { continue }
            guard type == .response else { continue }
            let response = try JSONDecoder().decode(RPCResponse.self, from: payload)
            guard response.id == request.id else { continue }

            if case .failure(let error) = response.result {
                info("\(label): ⚠️  \(error.code.rawValue) — \(error.message)")
            } else {
                ok("\(label)")
            }
            return response.result
        }
        fail("no response to \(label)")
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: Conversations

    /// Lists conversations, opens the busiest one, and waits for a live append.
    ///
    /// The wait is the part worth having. `listConversations` and
    /// `conversationMessages` are ordinary request/response and would pass
    /// against a desktop whose *streaming* was entirely broken — watching a
    /// message arrive unsolicited is the only thing that proves the
    /// subscribe → poll → push path is connected end to end.
    func exerciseConversations(waitingForAppend seconds: TimeInterval) throws {
        step("Conversations")
        guard case .conversations(let conversations) =
                try call(.listConversations(projectID: nil), label: "listConversations") else {
            return
        }
        guard !conversations.isEmpty else {
            info("no conversations — start Claude Code or Codex in a worktree and re-run")
            return
        }

        for conversation in conversations.prefix(10) {
            let when = conversation.lastActivityAt.map(Self.relative) ?? "never"
            info("• [\(conversation.agent.rawValue)] \(conversation.branch) — "
                 + "\(conversation.title ?? "untitled") "
                 + "(\(when)\(conversation.isLive ? ", live" : ""))")
        }

        let target = conversations.first { $0.isLive } ?? conversations[0]
        step("Opening \(target.branch)")

        guard case .conversationMessages(let page) = try call(
            .conversationMessages(conversationID: target.id, limit: 200),
            label: "conversationMessages") else { return }

        ok("\(page.messages.count) message(s)\(page.hasOlder ? " — older not sent" : "")")
        for message in page.messages.suffix(12) {
            let body = (message.text ?? "").replacingOccurrences(of: "\n", with: " ")
            let role = message.role.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            info("  \(Self.time(message.timestamp))  \(role)\(message.title)  "
                 + String(body.prefix(70)))
        }

        guard seconds > 0 else { return }
        step("Waiting \(Int(seconds))s for a live append — type at the agent to trigger one")
        let deadline = Date().addingTimeInterval(seconds)
        var appended = 0
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0,
                  let (type, payload) = try? receiveSealed(timeout: remaining),
                  type == .event,
                  let event = try? JSONDecoder().decode(ServerEvent.self, from: payload)
            else { continue }
            guard case .conversationMessagesAppended(let id, let messages) = event,
                  id == target.id else { continue }
            appended += messages.count
            for message in messages {
                ok("live → \(message.role.rawValue) \(message.title): "
                   + String((message.text ?? "").prefix(70)))
            }
        }
        if appended == 0 {
            info("no appends in that window — not a failure if the agent was idle")
        } else {
            ok("streamed \(appended) message(s)")
        }

        try call(.unwatchConversation(conversationID: target.id), label: "unwatchConversation")
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60:     return "just now"
        case ..<3600:   return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default:        return "\(seconds / 86_400)d ago"
        }
    }
}

/// A bounded receive that expired. Distinct from a transport error so the
/// streaming check can treat "nothing arrived" as information rather than as a
/// failure.
struct ProbeTimeout: Error {}

// MARK: - Entry point

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    print("""
    shiftover-probe — a command-line stand-in for Shiftover Go

      pair "<shiftover://pair?…>"    pair using a QR URL from Settings → Remote
      connect <host> <port>          reconnect using saved pairing state
    """)
    exit(0)
}

switch arguments[1] {

case "pair":
    guard arguments.count >= 3, let url = URL(string: arguments[2]) else {
        fail("usage: shiftover-probe pair \"shiftover://pair?…\"")
    }
    guard let code = RemotePairing.parse(url) else {
        fail("that does not look like a pairing URL")
    }

    step("Pairing with \(code.serviceName)")
    info("pairing id: \(code.pairingID)")

    // Resolve the Bonjour name to something connectable. The desktop advertises
    // over Bonjour; for the probe we take host/port on the command line instead
    // of implementing discovery, which is Go's job rather than this harness's.
    let host = ProcessInfo.processInfo.environment["SHIFTOVER_HOST"] ?? "127.0.0.1"
    let port = UInt16(ProcessInfo.processInfo.environment["SHIFTOVER_PORT"] ?? "0") ?? 0
    guard port != 0 else {
        fail("set SHIFTOVER_PORT (and optionally SHIFTOVER_HOST) — the listener uses a kernel-assigned port")
    }

    let identity = RemoteIdentityKey()
    let deviceID = UUID()
    let probe = Probe(identity: identity, deviceID: deviceID)

    step("Connecting to \(host):\(port)")
    try probe.connect(host: host, port: port)
    ok("socket open")

    step("Handshake")
    try probe.handshake(macPublicKey: code.publicKey, code: code, deviceName: "shiftover-probe")

    ProbeState(privateKey: identity.rawRepresentation, deviceID: deviceID,
               macPublicKey: code.publicKey, host: host, port: port).save()
    ok("saved pairing state to \(ProbeState.path.lastPathComponent)")

    step("Exercising the RPC surface")
    if case .projects(let projects) = try probe.call(.listProjects, label: "listProjects") {
        for project in projects { info("• \(project.name) (git: \(project.isGit))") }
    }
    if case .worktrees(let worktrees) =
        try probe.call(.listWorktrees(projectID: nil), label: "listWorktrees") {
        for wt in worktrees.prefix(10) {
            info("• \(wt.branch) — \(wt.agentStatus.rawValue)")
        }
    }
    try probe.call(.fleetSummary, label: "fleetSummary")
    try probe.call(.reviewItems, label: "reviewItems")

    step("Write-gated verb (expected to be refused — a new device is read-only)")
    try probe.call(.replyToAgent(worktreeID: UUID(), text: "hello"), label: "replyToAgent")

    try probe.exerciseConversations(waitingForAppend: 0)

    probe.close()
    print("\n✅ Done. Grant control in Settings → Remote, then re-run `connect` to test writes.\n")

case "connect":
    guard let state = ProbeState.load() else {
        fail("no saved pairing — run `pair` first")
    }
    guard let identity = RemoteIdentityKey(rawRepresentation: state.privateKey) else {
        fail("saved key is corrupt")
    }

    let host = arguments.count > 2 ? arguments[2] : state.host
    let port = arguments.count > 3 ? (UInt16(arguments[3]) ?? state.port) : state.port

    let probe = Probe(identity: identity, deviceID: state.deviceID)
    step("Reconnecting to \(host):\(port)")
    try probe.connect(host: host, port: port)
    ok("socket open")

    step("Handshake (returning device — no pairing code)")
    // The Mac must recognise us by PUBLIC KEY alone. If this succeeds, the
    // return path works; if it refuses, pairing did not persist.
    try probe.handshake(macPublicKey: state.macPublicKey, code: nil, deviceName: "shiftover-probe")

    step("Exercising the RPC surface")
    try probe.call(.listProjects, label: "listProjects")
    try probe.call(.fleetSummary, label: "fleetSummary")
    try probe.call(.replyToAgent(worktreeID: UUID(), text: "probe"), label: "replyToAgent")

    // Reconnect mode waits, because this is where streaming is worth proving:
    // the pairing run is a cold session with nothing appending yet.
    let wait = TimeInterval(ProcessInfo.processInfo.environment["SHIFTOVER_WAIT"] ?? "20") ?? 20
    try probe.exerciseConversations(waitingForAppend: wait)

    probe.close()
    print("\n✅ Done.\n")

default:
    fail("unknown command: \(arguments[1])")
}
