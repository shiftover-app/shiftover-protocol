import CryptoKit
import XCTest
@testable import ShiftoverProtocol

// MARK: - RemoteCryptoTests (PLAN_45 D5/D14)
//
// Security code, so the tests that matter are the adversarial ones. The happy
// path is table stakes; what is worth pinning is that tampering, substitution,
// replay and impersonation all FAIL — and fail closed. The Noise layer itself is
// pinned against the spec's test vector in `NoiseTests`.

final class RemoteHandshakeTests: XCTestCase {

    /// One Mac, one phone, and the code the Mac would display.
    private struct Rig {
        let mac = RemoteIdentityKey()
        let phone = RemoteIdentityKey()
        let deviceID = UUID()
        var code: RemotePairing.Code {
            RemotePairing.makeCode(serviceName: "Mac", publicKey: mac.publicKeyData)
        }
    }

    private let ack = HelloAckPayload(appVersion: "1.0", hostName: "Markos-MacBook-Pro",
                                      capabilities: [.read, .write])

    /// Runs a full handshake and returns both ends' view of it.
    private func connect(
        _ rig: Rig, redeeming code: RemotePairing.Code? = nil
    ) throws -> (incoming: RemoteHandshake.IncomingHello,
                 phone: RemoteChannel, mac: RemoteChannel, ack: HelloAckPayload) {
        let initiator = try RemoteHandshake.Initiator(identity: rig.phone,
                                                      macPublicKey: rig.mac.publicKeyData)
        let hello = try initiator.hello(appVersion: "0.1", deviceID: rig.deviceID,
                                        deviceName: "Marko's iPhone", redeeming: code)
        let responder = RemoteHandshake.Responder(identity: rig.mac)
        let incoming = try responder.open(try roundTrip(hello))
        let (helloAck, macChannel) = try responder.accept(ack)
        let (ackPayload, phoneChannel) = try initiator.finish(try roundTrip(helloAck))
        return (incoming, phoneChannel, macChannel, ackPayload)
    }

    /// Everything crosses the wire as JSON, so the tests do too.
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // ── The returning path ───────────────────────────────────────────────

    func testMacLearnsThePhonesProvenKeyAndIdentity() throws {
        let rig = Rig()
        let result = try connect(rig)
        XCTAssertEqual(result.incoming.phonePublicKey, rig.phone.publicKeyData)
        XCTAssertEqual(result.incoming.identity.deviceName, "Marko's iPhone")
        XCTAssertEqual(result.incoming.identity.deviceID, rig.deviceID)
        XCTAssertNil(result.incoming.identity.pairingID)
        XCTAssertNil(result.incoming.identity.pairingProof)
        XCTAssertEqual(result.ack, ack)
    }

    func testChannelCarriesFramesBothWays() throws {
        let result = try connect(Rig())
        XCTAssertEqual(try result.mac.open(try result.phone.seal(Data("req".utf8))), Data("req".utf8))
        XCTAssertEqual(try result.phone.open(try result.mac.seal(Data("res".utf8))), Data("res".utf8))
        XCTAssertEqual(result.phone.handshakeHash, result.mac.handshakeHash)
    }

    func testReplayedFrameIsRejected() throws {
        let result = try connect(Rig())
        let keystroke = try result.phone.seal(Data("y\r".utf8))
        _ = try result.mac.open(keystroke)
        XCTAssertThrowsError(try result.mac.open(keystroke))
    }

    func testHelloShowsNothingButTheVersionInTheClear() throws {
        let rig = Rig()
        let initiator = try RemoteHandshake.Initiator(identity: rig.phone,
                                                      macPublicKey: rig.mac.publicKeyData)
        let wire = try JSONEncoder().encode(
            try initiator.hello(appVersion: "0.1", deviceID: rig.deviceID,
                                deviceName: "Marko's iPhone"))
        let json = String(decoding: wire, as: UTF8.self)
        XCTAssertFalse(json.contains("iPhone"))
        XCTAssertFalse(json.contains(rig.deviceID.uuidString))
        XCTAssertNil(wire.range(of: rig.phone.publicKeyData))
        let probe = try JSONDecoder().decode(HandshakeVersionProbe.self, from: wire)
        XCTAssertEqual(probe.protocolVersion, ProtocolVersion.current)
    }

    func testPhoneDiallingAnImpostorMacGetsNoAnswer() throws {
        // The phone encrypts to the key it paired with. A different Mac — or a
        // man in the middle — cannot open message 1 at all.
        let rig = Rig()
        let initiator = try RemoteHandshake.Initiator(identity: rig.phone,
                                                      macPublicKey: rig.mac.publicKeyData)
        let hello = try initiator.hello(appVersion: "0.1", deviceID: rig.deviceID, deviceName: "x")
        XCTAssertThrowsError(try RemoteHandshake.Responder(identity: RemoteIdentityKey()).open(hello)) {
            guard case .cryptographic = $0 as? RemoteHandshakeError else {
                return XCTFail("expected a cryptographic failure, got \($0)")
            }
        }
    }

    func testHelloAckFromAnImpostorFailsOnThePhone() throws {
        // A man in the middle that answers with its own Noise responder cannot
        // produce a message 2 the phone accepts.
        let rig = Rig()
        let initiator = try RemoteHandshake.Initiator(identity: rig.phone,
                                                      macPublicKey: rig.mac.publicKeyData)
        let hello = try initiator.hello(appVersion: "0.1", deviceID: rig.deviceID, deviceName: "x")
        let real = RemoteHandshake.Responder(identity: rig.mac)
        _ = try real.open(hello)
        let (genuine, _) = try real.accept(ack)
        var forged = genuine.handshake
        forged[forged.startIndex + 40] ^= 0xFF
        XCTAssertThrowsError(try initiator.finish(HelloAck(handshake: forged)))
    }

    func testIncompatibleVersionIsReportedWithNumbers() throws {
        let rig = Rig()
        let initiator = try RemoteHandshake.Initiator(identity: rig.phone,
                                                      macPublicKey: rig.mac.publicKeyData)
        let real = try initiator.hello(appVersion: "0.1", deviceID: rig.deviceID, deviceName: "x")
        let stale = Hello(protocolVersion: 1, handshake: real.handshake)
        XCTAssertThrowsError(try RemoteHandshake.Responder(identity: rig.mac).open(stale)) {
            XCTAssertEqual($0 as? RemoteHandshakeError,
                           .incompatible(.peerTooOld(peer: 1,
                                                     minimumSupported: ProtocolVersion.minimumSupported)))
        }
    }

    func testPrologueCommitsToTheVersion() {
        // With one version in the window there is nothing to downgrade to yet,
        // so this pins the half that makes a future downgrade fail: each version
        // yields a distinct prologue. `NoiseSecurityTests
        // .testMismatchedPrologueFailsTheHandshake` pins the other half — a
        // prologue mismatch fails message 1.
        XCTAssertNotEqual(RemoteHandshake.prologue(protocolVersion: 2),
                          RemoteHandshake.prologue(protocolVersion: 3))
    }

    func testCodeForADifferentMacIsCaughtBeforeSending() throws {
        let rig = Rig()
        let initiator = try RemoteHandshake.Initiator(identity: rig.phone,
                                                      macPublicKey: rig.mac.publicKeyData)
        let otherMacsCode = RemotePairing.makeCode(serviceName: "Other",
                                                   publicKey: RemoteIdentityKey().publicKeyData)
        XCTAssertThrowsError(try initiator.hello(appVersion: "0.1", deviceID: rig.deviceID,
                                                 deviceName: "x", redeeming: otherMacsCode)) {
            XCTAssertEqual($0 as? RemoteHandshakeError, .codeDoesNotMatchHost)
        }
    }

    func testUnknownCapabilityInTheSealedAckDegrades() throws {
        // D16 inside the handshake: a newer Mac advertising something this build
        // has never heard of must not fail the whole connection.
        let json = #"{"appVersion":"9.9","hostName":"Mac","capabilities":["read","teleportation"]}"#
        let payload = try JSONDecoder().decode(HelloAckPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.capabilities, [.read, .unknown])
    }

    // ── Redeeming a code ─────────────────────────────────────────────────

    func testRedemptionCarriesAProofTheMacCanVerify() throws {
        let rig = Rig()
        let code = rig.code
        let result = try connect(rig, redeeming: code)
        let identity = result.incoming.identity
        XCTAssertEqual(identity.pairingID, code.pairingID)
        let proof = try XCTUnwrap(identity.pairingProof)
        XCTAssertTrue(RemotePairing.verifyPairingProof(
            proof, secret: code.secret, pairingID: code.pairingID,
            handshakeHash: result.incoming.handshakeHash))
    }

    func testProofFromOneHandshakeDoesNotVerifyInAnother() throws {
        // Binding to the handshake hash is what stops a captured proof — say,
        // from a connection that dropped — being presented again.
        let rig = Rig()
        let code = rig.code
        let first = try connect(rig, redeeming: code)
        let second = try connect(rig)
        let proof = try XCTUnwrap(first.incoming.identity.pairingProof)
        XCTAssertFalse(RemotePairing.verifyPairingProof(
            proof, secret: code.secret, pairingID: code.pairingID,
            handshakeHash: second.incoming.handshakeHash))
    }

    func testProofWithoutTheSecretFails() throws {
        let rig = Rig()
        let code = rig.code
        let result = try connect(rig, redeeming: code)
        let proof = try XCTUnwrap(result.incoming.identity.pairingProof)
        XCTAssertFalse(RemotePairing.verifyPairingProof(
            proof, secret: RemotePairing.randomBytes(RemotePairing.secretByteCount),
            pairingID: code.pairingID, handshakeHash: result.incoming.handshakeHash))
    }

    func testProofIsBoundToItsPairingID() throws {
        let rig = Rig()
        let code = rig.code
        let result = try connect(rig, redeeming: code)
        let proof = try XCTUnwrap(result.incoming.identity.pairingProof)
        XCTAssertFalse(RemotePairing.verifyPairingProof(
            proof, secret: code.secret, pairingID: "a-different-pairing",
            handshakeHash: result.incoming.handshakeHash))
    }

    func testGarbageProofIsRejected() {
        let secret = RemotePairing.randomBytes(RemotePairing.secretByteCount)
        let hash = RemotePairing.randomBytes(32)
        for bogus in [Data(), Data(repeating: 0, count: 32), RemotePairing.randomBytes(32)] {
            XCTAssertFalse(RemotePairing.verifyPairingProof(
                bogus, secret: secret, pairingID: "id", handshakeHash: hash))
        }
    }

    // ── Identity keys ────────────────────────────────────────────────────

    func testIdentityKeySurvivesSerialisation() throws {
        let original = RemoteIdentityKey()
        let restored = try XCTUnwrap(RemoteIdentityKey(rawRepresentation: original.rawRepresentation))
        XCTAssertEqual(restored.publicKeyData, original.publicKeyData)
    }

    func testMalformedMacKeyIsRejectedGracefully() {
        // A bad key comes from a scanned QR or a stored record — untrusted input,
        // so it must fail as an error, never trap.
        for bad in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0xFF, count: 64)] {
            XCTAssertThrowsError(try RemoteHandshake.Initiator(identity: RemoteIdentityKey(),
                                                               macPublicKey: bad))
        }
    }
}

// MARK: - Pairing

final class RemotePairingTests: XCTestCase {

    private func makeCode(now: Date = Date()) -> RemotePairing.Code {
        RemotePairing.makeCode(serviceName: "Markos-MacBook-Pro",
                               publicKey: RemoteIdentityKey().publicKeyData,
                               now: now)
    }

    func testCodeRoundTripsThroughItsURL() throws {
        let code = makeCode()
        let url = try XCTUnwrap(RemotePairing.url(for: code))
        let parsed = try XCTUnwrap(RemotePairing.parse(url))

        XCTAssertEqual(parsed.pairingID, code.pairingID)
        XCTAssertEqual(parsed.serviceName, code.serviceName)
        XCTAssertEqual(parsed.publicKey, code.publicKey)
        XCTAssertEqual(parsed.secret, code.secret)
    }

    func testEveryCodeIsUnique() {
        let codes = (0..<200).map { _ in makeCode() }
        XCTAssertEqual(Set(codes.map(\.pairingID)).count, 200)
        XCTAssertEqual(Set(codes.map(\.secret)).count, 200)
    }

    func testCodeExpires() {
        let past = Date().addingTimeInterval(-RemotePairing.codeLifetime - 1)
        XCTAssertTrue(makeCode(now: past).isExpired)
        XCTAssertFalse(makeCode().isExpired)
    }

    func testMalformedURLsAreRejected() {
        let cases = [
            "https://example.com/pair?v=1",                    // wrong scheme
            "shiftover://open?v=1",                            // wrong host
            "shiftover://pair?v=2&id=a&n=b&k=c&s=d",           // unknown version
            "shiftover://pair?v=1&n=b&k=c&s=d",                // no pairing id
            "shiftover://pair?v=1&id=a&n=b&k=short&s=d"        // bad key length
        ]
        for raw in cases {
            XCTAssertNil(RemotePairing.parse(URL(string: raw)!), "accepted: \(raw)")
        }
    }

    /// A 32-byte X25519 public key is the only acceptable shape — a shorter or
    /// longer one is either corruption or an attempt to confuse the parser.
    func testWrongLengthKeyIsRejected() throws {
        var components = URLComponents(string: "shiftover://pair")!
        components.queryItems = [
            .init(name: "v", value: "1"),
            .init(name: "id", value: "abc"),
            .init(name: "n", value: "Mac"),
            .init(name: "k", value: RemotePairing.base64url(Data(repeating: 0, count: 16))),
            .init(name: "s", value: RemotePairing.base64url(
                RemotePairing.randomBytes(RemotePairing.secretByteCount)))
        ]
        XCTAssertNil(RemotePairing.parse(components.url!))
    }
}
