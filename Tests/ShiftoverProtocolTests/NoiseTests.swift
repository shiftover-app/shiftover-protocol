import CryptoKit
import XCTest
@testable import ShiftoverProtocol

/// `Noise.swift` against the spec rather than against itself.
///
/// The vector is the `Noise_IK_25519_ChaChaPoly_SHA256` entry from the
/// cacophony test-vector set (as redistributed in the `snow` crate,
/// `tests/vectors/cacophony.txt`), copied verbatim. Every byte of both handshake
/// messages, the final handshake hash, and four transport messages has to
/// match — so a mistake in any token, the HKDF, the nonce encoding, the
/// associated data or the split direction fails here, not in the field.
final class NoiseVectorTests: XCTestCase {

    private enum Vector {
        static let prologue = "4a6f686e2047616c74"
        static let initStatic = "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"
        static let initEphemeral = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"
        static let respStatic = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"
        static let respEphemeral = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"
        static let initRemoteStatic = "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62"
        static let handshakeHash = "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7"
        static let messages: [(payload: String, ciphertext: String)] = [
            ("4c756477696720766f6e204d69736573",
             "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7"),
            ("4d757272617920526f746862617264",
             "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5"),
            ("462e20412e20486179656b",
             "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8"),
            ("4361726c204d656e676572",
             "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667"),
            ("4a65616e2d426170746973746520536179",
             "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4"),
            ("457567656e2042f6686d20766f6e2042617765726b",
             "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024"),
        ]
    }

    private func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: hex))
    }

    func testResponderStaticMatchesTheVectorsRemoteStatic() throws {
        // Guards the fixture itself: if this fails, the keys were mis-copied
        // and every assertion below would be meaningless.
        XCTAssertEqual(try key(Vector.respStatic).publicKey.rawRepresentation,
                       Data(hex: Vector.initRemoteStatic))
    }

    func testIKHandshakeAndTransportMatchCacophonyByteForByte() throws {
        let initiator = try NoiseIKInitiator(
            prologue: Data(hex: Vector.prologue),
            staticKey: try key(Vector.initStatic),
            remoteStaticKey: Data(hex: Vector.initRemoteStatic),
            ephemeralKey: try key(Vector.initEphemeral))
        let responder = NoiseIKResponder(
            prologue: Data(hex: Vector.prologue),
            staticKey: try key(Vector.respStatic),
            ephemeralKey: try key(Vector.respEphemeral))

        // Message 1: initiator → responder.
        let m1 = try initiator.writeMessage1 { _ in Data(hex: Vector.messages[0].payload) }
        XCTAssertEqual(m1.hex, Vector.messages[0].ciphertext)
        let first = try responder.readMessage1(m1)
        XCTAssertEqual(first.payload.hex, Vector.messages[0].payload)
        XCTAssertEqual(first.remoteStaticKey,
                       try key(Vector.initStatic).publicKey.rawRepresentation)

        // Message 2: responder → initiator.
        let (m2, responderTransport) = try responder.writeMessage2(
            payload: Data(hex: Vector.messages[1].payload))
        XCTAssertEqual(m2.hex, Vector.messages[1].ciphertext)
        let (payload2, initiatorTransport) = try initiator.readMessage2(m2)
        XCTAssertEqual(payload2.hex, Vector.messages[1].payload)

        XCTAssertEqual(initiatorTransport.handshakeHash.hex, Vector.handshakeHash)
        XCTAssertEqual(responderTransport.handshakeHash.hex, Vector.handshakeHash)

        // Transport: the vector alternates, initiator first.
        for (index, message) in Vector.messages.enumerated().dropFirst(2) {
            let initiatorSends = index % 2 == 0
            let (sender, receiver) = initiatorSends
                ? (initiatorTransport, responderTransport)
                : (responderTransport, initiatorTransport)
            let sealed = try sender.send.encrypt(Data(hex: message.payload))
            XCTAssertEqual(sealed.hex, message.ciphertext, "transport message \(index)")
            XCTAssertEqual(try receiver.receive.decrypt(sealed).hex, message.payload)
        }
    }

    func testPayloadClosureSeesTheHashTheResponderReports() throws {
        let initiatorKey = Curve25519.KeyAgreement.PrivateKey()
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseIKInitiator(
            prologue: Data(), staticKey: initiatorKey,
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        let responder = NoiseIKResponder(prologue: Data(), staticKey: responderKey)

        var seen: Data?
        let m1 = try initiator.writeMessage1 { hash in
            seen = hash
            return Data("hi".utf8)
        }
        let first = try responder.readMessage1(m1)
        XCTAssertEqual(first.handshakeHashBeforePayload, seen,
                       "a pairing proof is only checkable if both sides agree on this value")
    }
}

final class NoiseSecurityTests: XCTestCase {

    private struct Pair {
        let initiator: NoiseTransport
        let responder: NoiseTransport
    }

    private func handshake(
        initiatorKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        responderKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        prologue: Data = Data("test".utf8)
    ) throws -> Pair {
        let initiator = try NoiseIKInitiator(
            prologue: prologue, staticKey: initiatorKey,
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        let responder = NoiseIKResponder(prologue: prologue, staticKey: responderKey)
        _ = try responder.readMessage1(try initiator.writeMessage1 { _ in Data() })
        let (m2, responderTransport) = try responder.writeMessage2(payload: Data())
        let (_, initiatorTransport) = try initiator.readMessage2(m2)
        return Pair(initiator: initiatorTransport, responder: responderTransport)
    }

    func testMessageOneToTheWrongMacFailsToOpen() throws {
        // The phone thinks it is talking to `real`; `impostor` answers. Without
        // `real`'s private key the impostor cannot even read who is calling.
        let real = Curve25519.KeyAgreement.PrivateKey()
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseIKInitiator(
            prologue: Data(), staticKey: .init(),
            remoteStaticKey: real.publicKey.rawRepresentation)
        let m1 = try initiator.writeMessage1 { _ in Data("secret".utf8) }
        XCTAssertThrowsError(
            try NoiseIKResponder(prologue: Data(), staticKey: impostor).readMessage1(m1)
        ) { XCTAssertEqual($0 as? NoiseError, .decryptFailed) }
    }

    func testMessageOneHidesTheInitiatorsIdentityAndPayload() throws {
        let initiatorKey = Curve25519.KeyAgreement.PrivateKey()
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseIKInitiator(
            prologue: Data(), staticKey: initiatorKey,
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        let payload = Data("Marko's iPhone".utf8)
        let m1 = try initiator.writeMessage1 { _ in payload }
        // What v1 sent in the clear, and what an observer must no longer see.
        XCTAssertNil(m1.range(of: initiatorKey.publicKey.rawRepresentation))
        XCTAssertNil(m1.range(of: payload))
    }

    func testMismatchedPrologueFailsTheHandshake() throws {
        // The prologue carries the cleartext protocol version, so this is what
        // stops a man in the middle from editing it to force a downgrade.
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseIKInitiator(
            prologue: Data("v2".utf8), staticKey: .init(),
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        let m1 = try initiator.writeMessage1 { _ in Data() }
        XCTAssertThrowsError(
            try NoiseIKResponder(prologue: Data("v1".utf8), staticKey: responderKey).readMessage1(m1))
    }

    func testTamperedMessageTwoFailsOnThePhone() throws {
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseIKInitiator(
            prologue: Data(), staticKey: .init(),
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        let responder = NoiseIKResponder(prologue: Data(), staticKey: responderKey)
        _ = try responder.readMessage1(try initiator.writeMessage1 { _ in Data() })
        var (m2, _) = try responder.writeMessage2(payload: Data("capabilities".utf8))
        m2[m2.count - 1] ^= 0x01
        XCTAssertThrowsError(try initiator.readMessage2(m2))
    }

    func testBothDirectionsRoundTrip() throws {
        let pair = try handshake()
        let up = try pair.initiator.send.encrypt(Data("request".utf8))
        XCTAssertEqual(try pair.responder.receive.decrypt(up), Data("request".utf8))
        let down = try pair.responder.send.encrypt(Data("response".utf8))
        XCTAssertEqual(try pair.initiator.receive.decrypt(down), Data("response".utf8))
    }

    func testDirectionsUseDifferentKeys() throws {
        // Both counters start at zero, so a shared key would reuse every nonce.
        let pair = try handshake()
        let plaintext = Data("same".utf8)
        XCTAssertNotEqual(try pair.initiator.send.encrypt(plaintext),
                          try pair.responder.send.encrypt(plaintext))
    }

    func testReplayedFrameIsRejected() throws {
        // The v1 gap: any authentic frame used to open, so a captured keystroke
        // could be typed twice. Implicit nonces make position part of validity.
        let pair = try handshake()
        let frame = try pair.initiator.send.encrypt(Data("y\r".utf8))
        XCTAssertEqual(try pair.responder.receive.decrypt(frame), Data("y\r".utf8))
        XCTAssertThrowsError(try pair.responder.receive.decrypt(frame)) {
            XCTAssertEqual($0 as? NoiseError, .decryptFailed)
        }
    }

    func testForgedFrameDoesNotDesynchroniseTheStream() throws {
        let pair = try handshake()
        let first = try pair.initiator.send.encrypt(Data("one".utf8))
        XCTAssertThrowsError(try pair.responder.receive.decrypt(Data(repeating: 7, count: 40)))
        // The garbage did not consume a position, so the real frame still opens.
        XCTAssertEqual(try pair.responder.receive.decrypt(first), Data("one".utf8))
    }

    func testReorderedFramesAreRejected() throws {
        let pair = try handshake()
        _ = try pair.initiator.send.encrypt(Data("one".utf8))
        let second = try pair.initiator.send.encrypt(Data("two".utf8))
        XCTAssertThrowsError(try pair.responder.receive.decrypt(second))
    }

    func testEverySessionGetsFreshKeys() throws {
        // Same two identities, two handshakes: the ephemeral keys must make the
        // sessions unrelated — the forward-secrecy property in miniature.
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let one = try handshake(initiatorKey: a, responderKey: b)
        let two = try handshake(initiatorKey: a, responderKey: b)
        XCTAssertNotEqual(one.initiator.handshakeHash, two.initiator.handshakeHash)
        let frame = try one.initiator.send.encrypt(Data("x".utf8))
        XCTAssertThrowsError(try two.responder.receive.decrypt(frame))
    }

    func testTruncatedMessagesAreMalformedNotCrashes() throws {
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(
            try NoiseIKResponder(prologue: Data(), staticKey: responderKey)
                .readMessage1(Data(repeating: 1, count: 95))
        ) { XCTAssertEqual($0 as? NoiseError, .malformedMessage) }

        let initiator = try NoiseIKInitiator(
            prologue: Data(), staticKey: .init(),
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        _ = try initiator.writeMessage1 { _ in Data() }
        XCTAssertThrowsError(try initiator.readMessage2(Data(repeating: 1, count: 47))) {
            XCTAssertEqual($0 as? NoiseError, .malformedMessage)
        }
    }

    func testMethodsCalledOutOfOrderThrow() throws {
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseIKInitiator(
            prologue: Data(), staticKey: .init(),
            remoteStaticKey: responderKey.publicKey.rawRepresentation)
        _ = try initiator.writeMessage1 { _ in Data() }
        XCTAssertThrowsError(try initiator.writeMessage1 { _ in Data() }) {
            XCTAssertEqual($0 as? NoiseError, .outOfOrder)
        }
        XCTAssertThrowsError(
            try NoiseIKResponder(prologue: Data(), staticKey: responderKey).writeMessage2(payload: Data())
        ) { XCTAssertEqual($0 as? NoiseError, .outOfOrder) }
    }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
