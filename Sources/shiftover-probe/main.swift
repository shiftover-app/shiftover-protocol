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
//     shiftover-probe pair "shiftover://pair?v=1&id=…"   # first time
//     shiftover-probe connect <host> <port>              # subsequent
//
// Pairing state is kept in ./shiftover-probe-state.json — a throwaway, and
// deliberately not in the user's Application Support.

import CryptoKit
import Foundation
import ShiftoverProtocol

// MARK: - Persisted probe state

struct ProbeState: Codable {
    var privateKey: Data
    var deviceID: UUID
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

    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let deviceID: UUID
    private var inbound: RemoteFrameCipherBox?
    private var outbound: RemoteFrameCipherBox?

    private let connected = DispatchSemaphore(value: 0)

    init(identity: Curve25519.KeyAgreement.PrivateKey, deviceID: UUID) {
        self.identity = identity
        self.deviceID = deviceID
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func connect(host: String, port: UInt16) throws {
        // `ws://` — the desktop listener is still plaintext at the transport
        // layer (TLS-PSK is deferred). Frames are sealed regardless, which is
        // what this probe actually verifies.
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
            fail("timed out waiting for a frame")
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
        guard let outbound else { fail("no session keys — handshake first") }
        let plaintext = try JSONEncoder().encode(value)
        try sendRaw(Frame(type: type, payload: try outbound.seal(plaintext)))
    }

    private func receiveSealed() throws -> (FrameType, Data) {
        guard let inbound else { fail("no session keys") }
        let frame = try receiveRaw()
        return (frame.type, try inbound.open(frame.payload))
    }

    // MARK: Handshake

    /// Runs the handshake, optionally redeeming a pairing code.
    func handshake(code: RemotePairing.Code?, deviceName: String) throws {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        var pairingID: String?
        var tag: Data?
        if let code {
            pairingID = code.pairingID
            // The MITM defence: bind BOTH public keys to the one-time secret.
            tag = RemotePairing.authenticationTag(
                secret: code.secret,
                pairingID: code.pairingID,
                macPublicKey: code.publicKey,
                phonePublicKey: identity.publicKey.rawRepresentation)
        }

        let hello = Hello(
            appVersion: "probe",
            deviceID: deviceID,
            deviceName: deviceName,
            publicKey: identity.publicKey.rawRepresentation,
            sessionNonce: nonce,
            pairingID: pairingID,
            pairingTag: tag)

        try sendRaw(Frame(type: .hello, payload: try JSONEncoder().encode(hello)))

        let reply = try receiveRaw()
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
        ok("paired with \(ack.hostName) (Shiftover \(ack.appVersion))")
        info("capabilities: \(ack.capabilities.map(\.rawValue).sorted().joined(separator: ", "))")

        // Derive the same keys the Mac just derived.
        guard let macKey = code?.publicKey ?? storedMacKey,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
              let shared = try? identity.sharedSecretFromKeyAgreement(with: peer)
        else { fail("could not agree a session key") }

        let keys = RemoteSessionKeys.derive(
            sharedSecret: shared, macNonce: ack.sessionNonce, phoneNonce: nonce)
        // The Mac seals with macToPhone; we open with it, and seal with the other.
        inbound = RemoteFrameCipherBox(key: keys.macToPhone)
        outbound = RemoteFrameCipherBox(key: keys.phoneToMac)
        storedMacKey = macKey
    }

    var storedMacKey: Data?

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
}

/// Tiny wrapper so the probe can hold the cipher without importing the app.
final class RemoteFrameCipherBox {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    func seal(_ plaintext: Data) throws -> Data {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        counter += 1
        return try ChaChaPoly.seal(plaintext, using: key,
                                   nonce: try ChaChaPoly.Nonce(data: bytes)).combined
    }

    func open(_ combined: Data) throws -> Data {
        try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: combined), using: key)
    }
}

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

    let identity = Curve25519.KeyAgreement.PrivateKey()
    let deviceID = UUID()
    let probe = Probe(identity: identity, deviceID: deviceID)

    step("Connecting to \(host):\(port)")
    try probe.connect(host: host, port: port)
    ok("socket open")

    step("Handshake")
    try probe.handshake(code: code, deviceName: "shiftover-probe")

    ProbeState(privateKey: identity.rawRepresentation, deviceID: deviceID,
               host: host, port: port).save()
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

    probe.close()
    print("\n✅ Done. Grant control in Settings → Remote, then re-run `connect` to test writes.\n")

case "connect":
    guard let state = ProbeState.load() else {
        fail("no saved pairing — run `pair` first")
    }
    guard let identity = try? Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: state.privateKey) else {
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
    try probe.handshake(code: nil, deviceName: "shiftover-probe")

    step("Exercising the RPC surface")
    try probe.call(.listProjects, label: "listProjects")
    try probe.call(.fleetSummary, label: "fleetSummary")
    try probe.call(.replyToAgent(worktreeID: UUID(), text: "probe"), label: "replyToAgent")

    probe.close()
    print("\n✅ Done.\n")

default:
    fail("unknown command: \(arguments[1])")
}
