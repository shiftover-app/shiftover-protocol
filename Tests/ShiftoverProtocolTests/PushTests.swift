import XCTest
@testable import ShiftoverProtocol

/// The lock-screen push is workspace content crossing two parties that must not
/// read it. These pin that only the paired phone can open it, only the paired
/// Mac can have sealed it, and a stale or edited one is refused.
final class PushSealingTests: XCTestCase {

    private let mac = RemoteIdentityKey()
    private let phone = RemoteIdentityKey()

    private func content(sentAt: Date = Date(), body: String = "Allow Bash: rm -rf build?")
    -> PushContent {
        PushContent(kind: .permission, worktreeID: UUID(), title: "shiftover · feat/relay",
                    subtitle: "Needs your permission", body: body, sentAt: sentAt)
    }

    func testPairedPhoneOpensWhatThePairedMacSealed() throws {
        let original = content()
        let sealed = try PushSealing.seal(original, toPhoneKey: phone.publicKeyData, from: mac)
        let opened = try XCTUnwrap(PushSealing.open(sealed, with: phone,
                                                    fromAnyOf: [mac.publicKeyData]))
        XCTAssertEqual(opened.content, original)
        XCTAssertEqual(opened.macKey, mac.publicKeyData)
    }

    func testCiphertextShowsNothingOfTheQuestion() throws {
        let sealed = try PushSealing.seal(content(), toPhoneKey: phone.publicKeyData, from: mac)
        let wire = try JSONEncoder().encode(sealed)
        for secret in ["rm -rf", "shiftover", "feat/relay", "permission"] {
            XCTAssertNil(wire.range(of: Data(secret.utf8)), secret)
        }
    }

    func testAnotherPhoneCannotOpenIt() throws {
        let sealed = try PushSealing.seal(content(), toPhoneKey: phone.publicKeyData, from: mac)
        XCTAssertNil(PushSealing.open(sealed, with: RemoteIdentityKey(),
                                      fromAnyOf: [mac.publicKeyData]))
    }

    func testPushFromAnUnpairedSenderIsRefused() throws {
        // Anyone can encrypt to the phone's public key. Auth mode is what makes
        // "sealed by someone else" fail rather than show a forged question.
        let forger = RemoteIdentityKey()
        let sealed = try PushSealing.seal(content(), toPhoneKey: phone.publicKeyData, from: forger)
        XCTAssertNil(PushSealing.open(sealed, with: phone, fromAnyOf: [mac.publicKeyData]))
    }

    func testFindsWhichOfSeveralMacsSentIt() throws {
        let other = RemoteIdentityKey()
        let sealed = try PushSealing.seal(content(), toPhoneKey: phone.publicKeyData, from: mac)
        let opened = PushSealing.open(sealed, with: phone,
                                      fromAnyOf: [other.publicKeyData, mac.publicKeyData])
        XCTAssertEqual(opened?.macKey, mac.publicKeyData)
    }

    func testTamperedPushIsRefused() throws {
        let sealed = try PushSealing.seal(content(), toPhoneKey: phone.publicKeyData, from: mac)
        var ciphertext = sealed.ciphertext
        ciphertext[ciphertext.startIndex] ^= 0x01
        let edited = SealedPush(encapsulatedKey: sealed.encapsulatedKey, ciphertext: ciphertext)
        XCTAssertNil(PushSealing.open(edited, with: phone, fromAnyOf: [mac.publicKeyData]))
    }

    func testStalePushIsDropped() throws {
        // A relay that held a push back, or replays one, must not surface a
        // question that was answered long ago.
        let old = content(sentAt: Date().addingTimeInterval(-PushSealing.maxAge - 1))
        let sealed = try PushSealing.seal(old, toPhoneKey: phone.publicKeyData, from: mac)
        XCTAssertNil(PushSealing.open(sealed, with: phone, fromAnyOf: [mac.publicKeyData]))
    }

    func testLongBodiesAreCutToFitAPNs() throws {
        let long = String(repeating: "é", count: 5_000)   // 2 bytes each
        let sealed = try PushSealing.seal(content(body: long), toPhoneKey: phone.publicKeyData, from: mac)
        let body = try XCTUnwrap(PushSealing.open(sealed, with: phone,
                                                  fromAnyOf: [mac.publicKeyData])).content.body
        XCTAssertLessThanOrEqual(body.utf8.count, PushSealing.maxBodyBytes)
        XCTAssertTrue(body.hasSuffix("…"))
        // Envelope stays well inside APNs' 4 KB once base64'd.
        XCTAssertLessThan(try JSONEncoder().encode(sealed).count, 3_400)
    }

    func testTruncationNeverSplitsACharacter() {
        let cut = PushSealing.truncated("👍👍👍👍", maxBytes: 11)
        XCTAssertEqual(cut, "👍👍…")
        XCTAssertEqual(PushSealing.truncated("short", maxBytes: 100), "short")
    }

    func testCategoryIdentifiersAreStable() {
        XCTAssertEqual(content().categoryIdentifier, "shiftover.permission")
    }
}
