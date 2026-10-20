// MARK: - PresenceClientTests (PLAN_45 D9)
//
// Go against a fake Mac that checks presence the way the desktop does
// (`FakeMac.presence`). The keys here are software P-256 stand-ins for the
// Secure Enclave, which the test host does not have; what is pinned is that
// the client proves presence once per window, signs lock-screen answers for
// exactly that answer, holds keystrokes back until proven, and recovers when
// the Mac's window closed first.

import CryptoKit
import LocalAuthentication
import ShiftoverProtocol
import XCTest
@testable import ShiftoverClient

/// Software keys in place of the Secure Enclave.
@MainActor
final class SoftwarePresence: PresenceSigning {
    let owner = P256.Signing.PrivateKey()
    let unlocked = P256.Signing.PrivateKey()
    private(set) var signed: [PresenceLevel] = []

    nonisolated init() {}

    func presenceKeys() -> PresenceKeys? {
        PresenceKeys(owner: owner.publicKey.x963Representation,
                     unlocked: unlocked.publicKey.x963Representation)
    }

    func sign(_ message: Data, level: PresenceLevel, context: LAContext?) throws -> Data {
        signed.append(level)
        return try (level == .owner ? owner : unlocked).signature(for: message).derRepresentation
    }
}

@MainActor
final class PresenceClientTests: XCTestCase {

    private func connected(_ behavior: FakeMac.Behavior,
                           presence: PresenceSigning? = SoftwarePresence()) async throws
        -> (FakeMac, RemoteClient) {
        let mac = try await FakeMac.start(behavior)
        let client = RemoteClient(identity: RemoteIdentityKey(), deviceID: UUID(), deviceName: "Test iPhone")
        client.presence = presence
        try await client.connect(to: RemoteEndpoint(host: "127.0.0.1", port: mac.port),
                                 pairingCode: nil, knownMacPublicKey: mac.identity.publicKeyData)
        return (mac, client)
    }

    func testHelloCarriesThePresenceKeys() async throws {
        let presence = SoftwarePresence()
        let (mac, client) = try await connected(.presence, presence: presence)
        defer { client.disconnect(); mac.stop() }
        _ = try await client.listProjects()
        XCTAssertEqual(mac.helloPresenceKeys, presence.presenceKeys())
    }

    func testOneOwnerProofCoversAWindowOfWrites() async throws {
        let presence = SoftwarePresence()
        let (mac, client) = try await connected(.presence, presence: presence)
        defer { client.disconnect(); mac.stop() }

        try await client.perform(.interruptAgent(worktreeID: UUID()))
        try await client.perform(.interruptAgent(worktreeID: UUID()))
        XCTAssertEqual(mac.presenceProofs, 1)
        XCTAssertEqual(mac.writeRequestsHandled, 2)
        XCTAssertEqual(presence.signed, [.owner])
    }

    func testConcurrentWritesShareOneProof() async throws {
        let (mac, client) = try await connected(.presence)
        defer { client.disconnect(); mac.stop() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { @MainActor in
                    try await client.perform(.interruptAgent(worktreeID: UUID()))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(mac.presenceProofs, 1)
        XCTAssertEqual(mac.writeRequestsHandled, 5)
        XCTAssertEqual(mac.framesThatFailedToOpen, 0)
    }

    func testLockScreenAnswerCarriesItsOwnProofAndOpensNoWindow() async throws {
        let presence = SoftwarePresence()
        let (mac, client) = try await connected(.presence, presence: presence)
        defer { client.disconnect(); mac.stop() }

        try await client.answerFromNotification(.answerPermission(
            worktreeID: UUID(), allow: true, questionSentAt: Date()))
        try await client.answerFromNotification(.replyToAgent(
            worktreeID: UUID(), text: "yes", questionSentAt: Date()))
        XCTAssertEqual(mac.lockScreenAnswers, 2)
        XCTAssertEqual(mac.presenceProofs, 0)
        XCTAssertEqual(presence.signed, [.unlocked, .unlocked])
        XCTAssertFalse(client.sendTerminalInputNow(Data("y".utf8), paneID: UUID()),
                       "an unlocked proof must not open keystrokes")
    }

    func testKeystrokesWaitUntilPresenceIsProven() async throws {
        let (mac, client) = try await connected(.presence)
        defer { client.disconnect(); mac.stop() }
        let pane = UUID()

        XCTAssertFalse(client.sendTerminalInputNow(Data("a".utf8), paneID: pane))
        try await client.unlockWrites()
        XCTAssertTrue(client.sendTerminalInputNow(Data("b".utf8), paneID: pane))
        for _ in 0..<100 where mac.terminalBytes.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(String(decoding: mac.terminalBytes, as: UTF8.self), "b")
    }

    func testWriteIsRetriedOnceWhenTheMacsWindowClosedFirst() async throws {
        let (mac, client) = try await connected(.presenceClosesEarly)
        defer { client.disconnect(); mac.stop() }

        try await client.perform(.interruptAgent(worktreeID: UUID()))
        XCTAssertEqual(mac.presenceProofs, 2, "proved again after the refusal")
        XCTAssertEqual(mac.writeRequestsHandled, 1, "and the write went through exactly once")
    }

    func testWithoutKeysAWriteSaysWhatToFix() async throws {
        let (mac, client) = try await connected(.presence, presence: nil)
        defer { client.disconnect(); mac.stop() }
        do {
            try await client.perform(.interruptAgent(worktreeID: UUID()))
            XCTFail("a phone without presence keys wrote to a Mac that checks them")
        } catch let error as RemoteClient.ClientError {
            XCTAssertEqual(error, .presenceUnavailable)
            XCTAssertTrue(error.userMessage.contains("passcode"))
        }
        XCTAssertEqual(mac.writeRequestsHandled, 0)
    }

    func testAMacThatDoesNotCheckPresenceGetsNoProofs() async throws {
        let presence = SoftwarePresence()
        let (mac, client) = try await connected(.accept, presence: presence)
        defer { client.disconnect(); mac.stop() }
        try await client.perform(.interruptAgent(worktreeID: UUID()))
        XCTAssertTrue(presence.signed.isEmpty)
        XCTAssertTrue(client.sendTerminalInputNow(Data("x".utf8), paneID: UUID()))
    }
}
