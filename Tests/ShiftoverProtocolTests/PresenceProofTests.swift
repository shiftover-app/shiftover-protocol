import CryptoKit
import XCTest
@testable import ShiftoverProtocol

// MARK: - PresenceProofTests (PLAN_45 D9)
//
// The Mac decides whether a phone may write from these checks alone, so the
// tests that matter are the refusals: a proof for one connection, counter,
// level or answer must not verify as another.

final class PresenceProofTests: XCTestCase {

    private let owner = P256.Signing.PrivateKey()
    private let unlocked = P256.Signing.PrivateKey()
    private let handshakeHash = Data(SHA256.hash(data: Data("session".utf8)))

    private var keys: PresenceKeys {
        PresenceKeys(owner: owner.publicKey.x963Representation,
                     unlocked: unlocked.publicKey.x963Representation)
    }

    private func assertion(_ level: PresenceLevel, counter: UInt64 = 1,
                           hash: Data? = nil, binding: Data = Data(),
                           signer: P256.Signing.PrivateKey? = nil) throws -> PresenceAssertion {
        let message = PresenceProof.message(level: level, counter: counter,
                                            handshakeHash: hash ?? handshakeHash, binding: binding)
        let key = signer ?? (level == .owner ? owner : unlocked)
        return PresenceAssertion(level: level, counter: counter,
                                 signature: try key.signature(for: message).derRepresentation)
    }

    // ── Verification ─────────────────────────────────────────────────────

    func testOwnerProofVerifiesForItsConnection() throws {
        XCTAssertTrue(PresenceProof.verify(try assertion(.owner), keys: keys,
                                           handshakeHash: handshakeHash))
    }

    func testProofFromAnotherConnectionFails() throws {
        let other = Data(SHA256.hash(data: Data("other session".utf8)))
        XCTAssertFalse(PresenceProof.verify(try assertion(.owner, hash: other), keys: keys,
                                            handshakeHash: handshakeHash))
    }

    func testUnlockedKeyCannotPassAsOwner() throws {
        // Signed by the unlocked key but labelled owner: checked against the
        // owner key, so it fails.
        let forged = try assertion(.owner, signer: unlocked)
        XCTAssertFalse(PresenceProof.verify(forged, keys: keys, handshakeHash: handshakeHash))
    }

    func testRelabelledLevelFails() throws {
        // An unlocked signature relabelled as owner: different message, different key.
        let real = try assertion(.unlocked)
        let relabelled = PresenceAssertion(level: .owner, counter: real.counter, signature: real.signature)
        XCTAssertFalse(PresenceProof.verify(relabelled, keys: keys, handshakeHash: handshakeHash))
    }

    func testChangedCounterFails() throws {
        let real = try assertion(.owner, counter: 3)
        let bumped = PresenceAssertion(level: .owner, counter: 4, signature: real.signature)
        XCTAssertFalse(PresenceProof.verify(bumped, keys: keys, handshakeHash: handshakeHash))
    }

    func testTamperedSignatureFails() throws {
        var signature = try assertion(.owner).signature
        signature[signature.count - 1] ^= 0x01
        let tampered = PresenceAssertion(level: .owner, counter: 1, signature: signature)
        XCTAssertFalse(PresenceProof.verify(tampered, keys: keys, handshakeHash: handshakeHash))
    }

    func testGarbageSignatureFailsWithoutThrowing() {
        let garbage = PresenceAssertion(level: .owner, counter: 1, signature: Data([1, 2, 3]))
        XCTAssertFalse(PresenceProof.verify(garbage, keys: keys, handshakeHash: handshakeHash))
    }

    func testProofForOneAnswerCannotBeSpentOnAnother() throws {
        let worktree = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_790_000_000.123)
        let allow = try XCTUnwrap(PresenceProof.notificationBinding(
            for: .answerPermission(worktreeID: worktree, allow: true, questionSentAt: sentAt)))
        let deny = try XCTUnwrap(PresenceProof.notificationBinding(
            for: .answerPermission(worktreeID: worktree, allow: false, questionSentAt: sentAt)))
        let proof = try assertion(.unlocked, binding: allow)
        XCTAssertTrue(PresenceProof.verify(proof, keys: keys, handshakeHash: handshakeHash, binding: allow))
        XCTAssertFalse(PresenceProof.verify(proof, keys: keys, handshakeHash: handshakeHash, binding: deny))
    }

    // ── Bindings ─────────────────────────────────────────────────────────

    func testOnlyNotificationAnswersHaveABinding() {
        let worktree = UUID()
        XCTAssertNil(PresenceProof.notificationBinding(
            for: .answerPermission(worktreeID: worktree, allow: true, questionSentAt: nil)))
        XCTAssertNil(PresenceProof.notificationBinding(
            for: .replyToAgent(worktreeID: worktree, text: "go")))
        XCTAssertNil(PresenceProof.notificationBinding(for: .approveAndMerge(worktreeID: worktree)))
        XCTAssertNil(PresenceProof.notificationBinding(for: .interruptAgent(worktreeID: worktree)))
        XCTAssertNotNil(PresenceProof.notificationBinding(
            for: .replyToAgent(worktreeID: worktree, text: "go", questionSentAt: Date())))
    }

    func testBindingsDifferByEveryField() {
        let sentAt = Date(timeIntervalSince1970: 1_790_000_000)
        let a = UUID(), b = UUID()
        let bindings = [
            PresenceProof.notificationBinding(for: .replyToAgent(worktreeID: a, text: "yes", questionSentAt: sentAt)),
            PresenceProof.notificationBinding(for: .replyToAgent(worktreeID: b, text: "yes", questionSentAt: sentAt)),
            PresenceProof.notificationBinding(for: .replyToAgent(worktreeID: a, text: "no", questionSentAt: sentAt)),
            PresenceProof.notificationBinding(for: .replyToAgent(worktreeID: a, text: "yes",
                                                                 questionSentAt: sentAt.addingTimeInterval(1))),
            PresenceProof.notificationBinding(for: .answerPermission(worktreeID: a, allow: true, questionSentAt: sentAt)),
        ]
        XCTAssertEqual(Set(bindings.compactMap { $0 }).count, bindings.count)
    }

    /// The phone signs the binding of the method it builds; the Mac checks the
    /// binding of the method it decoded. They must agree after JSON.
    func testBindingSurvivesTheWire() throws {
        let method = RPCMethod.answerPermission(
            worktreeID: UUID(), allow: true,
            questionSentAt: Date(timeIntervalSince1970: 1_790_000_000.4567))
        let decoded = try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method))
        XCTAssertEqual(PresenceProof.notificationBinding(for: method),
                       PresenceProof.notificationBinding(for: decoded))
    }

    // ── Keys ─────────────────────────────────────────────────────────────

    func testKeysMustBeTwoDifferentPoints() {
        XCTAssertTrue(keys.isWellFormed)
        let same = owner.publicKey.x963Representation
        XCTAssertFalse(PresenceKeys(owner: same, unlocked: same).isWellFormed)
        XCTAssertFalse(PresenceKeys(owner: Data(repeating: 4, count: 65), unlocked: same).isWellFormed)
    }

    // ── Wire compatibility ───────────────────────────────────────────────

    func testHelloCarriesPresenceKeysToTheMac() throws {
        let mac = RemoteIdentityKey()
        let initiator = try RemoteHandshake.Initiator(identity: RemoteIdentityKey(),
                                                      macPublicKey: mac.publicKeyData)
        let hello = try initiator.hello(appVersion: "1", deviceID: UUID(), deviceName: "Phone",
                                        presenceKeys: keys)
        let incoming = try RemoteHandshake.Responder(identity: mac).open(hello)
        XCTAssertEqual(incoming.identity.presenceKeys, keys)
    }

    func testOlderShapesStillDecode() throws {
        let identity = #"{"appVersion":"0.9","deviceID":"\#(UUID().uuidString)","deviceName":"Old"}"#
        XCTAssertNil(try JSONDecoder().decode(HelloIdentity.self, from: Data(identity.utf8)).presenceKeys)

        let request = RPCRequest(method: .replyToAgent(worktreeID: UUID(), text: "hi"))
        let encoded = try JSONEncoder().encode(request)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("presence"))
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: encoded)
        XCTAssertNil(decoded.presence)
        guard case .replyToAgent(_, "hi", nil) = decoded.method else {
            return XCTFail("a reply without a notification timestamp must decode with none")
        }
    }

    func testProvingPresenceIsNotItselfAWrite() throws {
        XCTAssertFalse(RPCMethod.provePresence(try assertion(.owner)).isWrite)
    }
}
