import CryptoKit
import XCTest
@testable import ShiftoverProtocol

/// A Live Activity's content reaches the phone as an ActivityKit push, whose
/// content state the relay and Apple can read. These pin that it is sealed like
/// a notification — only the paired phone opens it, only the paired Mac can
/// have sealed it — that it fits a push, and the order and rules it is drawn by.
final class LiveActivityTests: XCTestCase {

    private let mac = RemoteIdentityKey()
    private let phone = RemoteIdentityKey()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ status: AgentStatusDTO, since: TimeInterval = 0, project: String = "shiftover",
                       branch: String = "feat/relay") -> AgentsActivityContent.Agent {
        .init(worktreeID: UUID(), paneID: UUID(), project: project, branch: branch, agent: "claude",
              status: status, since: now.addingTimeInterval(since))
    }

    private func content(_ agents: [AgentsActivityContent.Agent], limit: AgentsActivityContent.Limit? = nil)
    -> AgentsActivityContent {
        AgentsActivityContent(macName: "MacBook Pro", agents: agents, limit: limit, sentAt: now)
    }

    // MARK: Sealing

    func testPairedPhoneOpensWhatThePairedMacSealed() throws {
        let original = content([agent(.permission), agent(.working)])
        let sealed = try ActivitySealing.seal(original, toPhoneKey: phone.publicKeyData, from: mac)
        let opened = try XCTUnwrap(ActivitySealing.open(sealed, with: phone, fromAnyOf: [mac.publicKeyData],
                                                        now: now))
        XCTAssertEqual(opened.content, original)
        XCTAssertEqual(opened.macKey, mac.publicKeyData)
    }

    func testSealedContentShowsNoNames() throws {
        let sealed = try ActivitySealing.seal(content([agent(.permission, project: "secret-project",
                                                             branch: "fix/payroll")]),
                                              toPhoneKey: phone.publicKeyData, from: mac)
        let wire = try JSONEncoder().encode(sealed)
        for secret in ["secret-project", "fix/payroll", "MacBook", "claude", "permission"] {
            XCTAssertNil(wire.range(of: Data(secret.utf8)), secret)
        }
    }

    func testAnUnpairedSenderOrAnotherPhoneIsRefused() throws {
        let forged = try ActivitySealing.seal(content([agent(.working)]), toPhoneKey: phone.publicKeyData,
                                              from: RemoteIdentityKey())
        XCTAssertNil(ActivitySealing.open(forged, with: phone, fromAnyOf: [mac.publicKeyData], now: now))
        let sealed = try ActivitySealing.seal(content([agent(.working)]), toPhoneKey: phone.publicKeyData,
                                              from: mac)
        XCTAssertNil(ActivitySealing.open(sealed, with: RemoteIdentityKey(), fromAnyOf: [mac.publicKeyData],
                                          now: now))
    }

    /// The `info` label keeps a box sealed for one purpose from opening as the
    /// other: activity content sealed under the notification label is refused,
    /// though it would decode.
    func testActivityContentSealedAsANotificationDoesNotOpen() throws {
        let plaintext = try JSONEncoder().encode(content([agent(.done)]))
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: phone.publicKeyData)
        let underPushLabel = try PushSealing.sealData(plaintext, info: PushSealing.info, to: recipient, from: mac)
        XCTAssertNil(ActivitySealing.open(underPushLabel, with: phone, fromAnyOf: [mac.publicKeyData], now: now))
        let underActivityLabel = try PushSealing.sealData(plaintext, info: ActivitySealing.info, to: recipient,
                                                          from: mac)
        XCTAssertNotNil(ActivitySealing.open(underActivityLabel, with: phone, fromAnyOf: [mac.publicKeyData],
                                             now: now))
    }

    /// Content stands until the next update, so an hour-old one still opens;
    /// one dated in the future does not.
    func testOldContentOpensButFutureContentDoesNot() throws {
        let sealed = try ActivitySealing.seal(content([agent(.working)]), toPhoneKey: phone.publicKeyData,
                                              from: mac)
        XCTAssertNotNil(ActivitySealing.open(sealed, with: phone, fromAnyOf: [mac.publicKeyData],
                                             now: now.addingTimeInterval(3 * 3600)))
        XCTAssertNil(ActivitySealing.open(sealed, with: phone, fromAnyOf: [mac.publicKeyData],
                                          now: now.addingTimeInterval(-120)))
    }

    /// The relay puts the box in `content-state`, beside `aps` fields, under
    /// APNs' 4 KB cap — even at the most agents and the longest names.
    func testTheLargestContentFitsAPush() throws {
        let long = String(repeating: "ä", count: 200)
        let agents = (0..<10).map { _ in agent(.permission, project: long, branch: long) }
        let limit = AgentsActivityContent.Limit(providerID: "claude", providerName: "Claude",
                                                resetsAt: now, resuming: 3, weeklyPercent: 61.5,
                                                weeklyResetsAt: now)
        let sealed = try ActivitySealing.seal(content(agents, limit: limit), toPhoneKey: phone.publicKeyData,
                                              from: mac)
        let state = sealed.encapsulatedKey.base64EncodedString().count + sealed.ciphertext.base64EncodedString().count
        XCTAssertLessThan(state, 3_200)
    }

    func testMacTagIsStableAndOpaque() {
        XCTAssertEqual(ActivitySealing.macTag(mac.publicKeyData), ActivitySealing.macTag(mac.publicKeyData))
        XCTAssertNotEqual(ActivitySealing.macTag(mac.publicKeyData), ActivitySealing.macTag(phone.publicKeyData))
        XCTAssertEqual(ActivitySealing.macTag(mac.publicKeyData).count, 16)
        XCTAssertFalse(ActivitySealing.macTag(mac.publicKeyData)
            .contains(mac.publicKeyData.prefix(8).map { String(format: "%02x", $0) }.joined()))
    }

    // MARK: Content

    func testWaitingComesFirstThenErrorsWorkAndFinishedTurns() {
        let done = agent(.done, since: -60)
        let working = agent(.working, since: -600)
        let error = agent(.error, since: -30)
        let question = agent(.input, since: -10)
        let listed = content([done, working, error, question]).agents
        XCTAssertEqual(listed.map(\.status), [.input, .error, .working, .done])
    }

    func testLongestWaitingFirstButNewestFinishedFirst() {
        let askedEarly = agent(.permission, since: -300), askedLate = agent(.input, since: -10)
        XCTAssertEqual(content([askedLate, askedEarly]).agents.map(\.worktreeID),
                       [askedEarly.worktreeID, askedLate.worktreeID])
        let finishedEarly = agent(.done, since: -300), finishedLate = agent(.done, since: -10)
        XCTAssertEqual(content([finishedEarly, finishedLate]).agents.map(\.worktreeID),
                       [finishedLate.worktreeID, finishedEarly.worktreeID])
    }

    func testIdleAgentsAreLeftOutAndTheRestCounted() {
        let many = (0..<6).map { _ in agent(.working) } + [agent(.idle), agent(.present)]
        let c = content(many)
        XCTAssertEqual(c.agents.count, AgentsActivityContent.maxAgents)
        XCTAssertEqual(c.agentCount, 6)
    }

    func testOnlyWorkWaitingOrALimitKeepsItActive() {
        XCTAssertTrue(content([agent(.working)]).isActive)
        XCTAssertTrue(content([agent(.permission)]).isActive)
        XCTAssertFalse(content([agent(.done), agent(.error)]).isActive)
        XCTAssertFalse(content([]).isActive)
        XCTAssertTrue(content([], limit: .init(providerID: "claude", providerName: "Claude", resetsAt: now,
                                               resuming: 0)).isActive)
    }

    func testLongNamesAreCut() {
        let a = agent(.working, project: String(repeating: "p", count: 100), branch: "main")
        XCTAssertEqual(a.project.count, 60)
        XCTAssertTrue(a.project.hasSuffix("…"))
        XCTAssertEqual(a.branch, "main")
    }

    func testShowsSameIgnoresWhenItWasSent() {
        let a = agent(.working)
        let first = AgentsActivityContent(macName: "Mac", agents: [a], limit: nil, sentAt: now)
        let later = AgentsActivityContent(macName: "Mac", agents: [a], limit: nil, sentAt: now.addingTimeInterval(60))
        XCTAssertTrue(first.showsSame(as: later))
        XCTAssertFalse(first.showsSame(as: AgentsActivityContent(macName: "Mac", agents: [agent(.done)],
                                                                 limit: nil, sentAt: now)))
    }
}
