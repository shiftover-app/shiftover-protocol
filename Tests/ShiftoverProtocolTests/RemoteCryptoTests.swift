import CryptoKit
import XCTest
@testable import ShiftoverProtocol

// MARK: - RemoteCryptoTests (PLAN_45 D5/D14)
//
// Security code, so the tests that matter are the adversarial ones. The happy
// path is table stakes; what is worth pinning is that tampering, substitution,
// replay and nonce reuse all FAIL — and fail closed.

final class RemoteCryptoTests: XCTestCase {

    // ── Session keys ─────────────────────────────────────────────────────

    private func agreedSecret() -> (SharedSecret, SharedSecret) {
        let mac = RemoteIdentityKey()
        let phone = RemoteIdentityKey()
        return (mac.sharedSecret(withPeerPublicKey: phone.publicKeyData)!,
                phone.sharedSecret(withPeerPublicKey: mac.publicKeyData)!)
    }

    func testBothSidesDeriveIdenticalKeys() throws {
        let (macSide, phoneSide) = agreedSecret()
        let nonceA = RemotePairing.randomBytes(32)
        let nonceB = RemotePairing.randomBytes(32)

        let macKeys = RemoteSessionKeys.derive(
            sharedSecret: macSide, macNonce: nonceA, phoneNonce: nonceB)
        let phoneKeys = RemoteSessionKeys.derive(
            sharedSecret: phoneSide, macNonce: nonceA, phoneNonce: nonceB)

        // Round-trip through the cipher rather than comparing SymmetricKeys:
        // agreeing on bytes is not the property that matters, interoperating is.
        let sealed = try RemoteFrameCipher(key: macKeys.macToPhone).seal(Data("hello".utf8))
        let opened = try RemoteFrameCipher(key: phoneKeys.macToPhone).open(sealed)
        XCTAssertEqual(opened, Data("hello".utf8))
    }

    /// The two directions must NOT share a key. Both peers count nonces from
    /// zero independently, so a shared key would collide on every single frame —
    /// which leaks the XOR of two plaintexts and breaks authentication.
    func testDirectionsUseDifferentKeys() throws {
        let (macSide, _) = agreedSecret()
        let keys = RemoteSessionKeys.derive(
            sharedSecret: macSide,
            macNonce: RemotePairing.randomBytes(32),
            phoneNonce: RemotePairing.randomBytes(32))

        let sealed = try RemoteFrameCipher(key: keys.macToPhone).seal(Data("secret".utf8))
        XCTAssertThrowsError(try RemoteFrameCipher(key: keys.phoneToMac).open(sealed),
                             "a frame sealed for one direction must not open with the other's key")
    }

    /// Fresh nonces are why a session key is not merely a function of the two
    /// identity keys. Without them every session between a pair would reuse one
    /// key while the counters restarted from zero.
    func testFreshNoncesProduceFreshKeys() throws {
        let (secret, _) = agreedSecret()
        let fixed = RemotePairing.randomBytes(32)

        let first = RemoteSessionKeys.derive(
            sharedSecret: secret, macNonce: fixed, phoneNonce: RemotePairing.randomBytes(32))
        let second = RemoteSessionKeys.derive(
            sharedSecret: secret, macNonce: fixed, phoneNonce: RemotePairing.randomBytes(32))

        let sealed = try RemoteFrameCipher(key: first.macToPhone).seal(Data("x".utf8))
        XCTAssertThrowsError(try RemoteFrameCipher(key: second.macToPhone).open(sealed))
    }

    func testDifferentPairsCannotReadEachOther() throws {
        let (aliceSecret, _) = agreedSecret()
        let (malorySecret, _) = agreedSecret()
        let salt = RemotePairing.randomBytes(32)

        let alice = RemoteSessionKeys.derive(sharedSecret: aliceSecret,
                                             macNonce: salt, phoneNonce: salt)
        let malory = RemoteSessionKeys.derive(sharedSecret: malorySecret,
                                              macNonce: salt, phoneNonce: salt)

        let sealed = try RemoteFrameCipher(key: alice.macToPhone).seal(Data("private".utf8))
        XCTAssertThrowsError(try RemoteFrameCipher(key: malory.macToPhone).open(sealed))
    }

    // ── Frame cipher ─────────────────────────────────────────────────────

    private func cipherPair() -> (RemoteFrameCipher, RemoteFrameCipher) {
        let key = SymmetricKey(size: .bits256)
        return (RemoteFrameCipher(key: key), RemoteFrameCipher(key: key))
    }

    func testSealOpenRoundTrip() throws {
        let (sender, receiver) = cipherPair()
        for payload in [Data(), Data("hi".utf8), Data(repeating: 0xAB, count: 100_000)] {
            XCTAssertEqual(try receiver.open(try sender.seal(payload)), payload)
        }
    }

    /// Identical plaintext must not produce identical ciphertext — otherwise an
    /// observer learns when a repeated command is sent, which for a terminal
    /// stream is a meaningful leak (think a repeated keystroke or prompt).
    func testRepeatedPlaintextProducesDistinctCiphertext() throws {
        let (sender, _) = cipherPair()
        let payload = Data("ls -la\r".utf8)
        let outputs = try (0..<50).map { _ in try sender.seal(payload) }
        XCTAssertEqual(Set(outputs).count, 50)
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let (sender, receiver) = cipherPair()
        var sealed = try sender.seal(Data("transfer $10".utf8))

        // Flip one bit somewhere in the middle of the body.
        let index = sealed.index(sealed.startIndex, offsetBy: sealed.count / 2)
        sealed[index] ^= 0x01

        XCTAssertThrowsError(try receiver.open(sealed))
    }

    func testTruncatedFrameFailsToOpen() throws {
        let (sender, receiver) = cipherPair()
        let sealed = try sender.seal(Data("some output".utf8))
        XCTAssertThrowsError(try receiver.open(sealed.dropLast(1)))
        XCTAssertThrowsError(try receiver.open(Data()))
    }

    /// Out-of-order delivery must still open. The nonce travels with the frame
    /// rather than being re-derived from a local counter precisely so a
    /// reordered or dropped frame does not desynchronise the whole stream.
    func testOutOfOrderFramesStillOpen() throws {
        let (sender, receiver) = cipherPair()
        let first = try sender.seal(Data("first".utf8))
        let second = try sender.seal(Data("second".utf8))

        XCTAssertEqual(try receiver.open(second), Data("second".utf8))
        XCTAssertEqual(try receiver.open(first), Data("first".utf8))
    }

    // ── Identity keys ────────────────────────────────────────────────────

    func testIdentityKeySurvivesSerialisation() throws {
        let original = RemoteIdentityKey()
        let restored = try XCTUnwrap(RemoteIdentityKey(rawRepresentation: original.rawRepresentation))
        XCTAssertEqual(restored.publicKeyData, original.publicKeyData)
    }

    /// Malformed peer input returns nil rather than throwing or trapping — a bad
    /// key arrives from the network and is an untrusted-input condition, not a
    /// programming error.
    func testMalformedPeerKeyIsRejectedGracefully() {
        let key = RemoteIdentityKey()
        XCTAssertNil(key.sharedSecret(withPeerPublicKey: Data()))
        XCTAssertNil(key.sharedSecret(withPeerPublicKey: Data(repeating: 0, count: 31)))
        XCTAssertNil(key.sharedSecret(withPeerPublicKey: Data(repeating: 0xFF, count: 64)))
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

    // ── The MITM defence ─────────────────────────────────────────────────

    func testMatchingTagVerifies() {
        let code = makeCode()
        let phone = RemoteIdentityKey().publicKeyData
        let tag = RemotePairing.authenticationTag(
            secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: phone)

        XCTAssertTrue(RemotePairing.verify(
            tag: tag, secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: phone))
    }

    /// **The attack this whole mechanism exists to stop.** A man in the middle
    /// substitutes their own public key for the phone's; without the secret they
    /// cannot produce a matching tag, so the Mac refuses.
    func testSubstitutedPhoneKeyFailsVerification() {
        let code = makeCode()
        let realPhone = RemoteIdentityKey().publicKeyData
        let attacker = RemoteIdentityKey().publicKeyData

        let tag = RemotePairing.authenticationTag(
            secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: realPhone)

        XCTAssertFalse(RemotePairing.verify(
            tag: tag, secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: attacker))
    }

    func testSubstitutedMacKeyFailsVerification() {
        let code = makeCode()
        let phone = RemoteIdentityKey().publicKeyData
        let attacker = RemoteIdentityKey().publicKeyData

        let tag = RemotePairing.authenticationTag(
            secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: phone)

        XCTAssertFalse(RemotePairing.verify(
            tag: tag, secret: code.secret, pairingID: code.pairingID,
            macPublicKey: attacker, phonePublicKey: phone))
    }

    /// Without the secret an attacker cannot forge a tag even knowing both
    /// public keys — which are, after all, public.
    func testWrongSecretFailsVerification() {
        let code = makeCode()
        let phone = RemoteIdentityKey().publicKeyData
        let tag = RemotePairing.authenticationTag(
            secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: phone)

        XCTAssertFalse(RemotePairing.verify(
            tag: tag, secret: RemotePairing.randomBytes(RemotePairing.secretByteCount),
            pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: phone))
    }

    /// The pairing id is in the HMAC input so a tag captured from one pairing
    /// cannot be replayed into another.
    func testTagIsBoundToItsPairingID() {
        let code = makeCode()
        let phone = RemoteIdentityKey().publicKeyData
        let tag = RemotePairing.authenticationTag(
            secret: code.secret, pairingID: code.pairingID,
            macPublicKey: code.publicKey, phonePublicKey: phone)

        XCTAssertFalse(RemotePairing.verify(
            tag: tag, secret: code.secret, pairingID: "a-different-pairing",
            macPublicKey: code.publicKey, phonePublicKey: phone))
    }

    func testGarbageTagIsRejected() {
        let code = makeCode()
        let phone = RemoteIdentityKey().publicKeyData
        for bogus in [Data(), Data(repeating: 0, count: 32), RemotePairing.randomBytes(32)] {
            XCTAssertFalse(RemotePairing.verify(
                tag: bogus, secret: code.secret, pairingID: code.pairingID,
                macPublicKey: code.publicKey, phonePublicKey: phone))
        }
    }
}
