import XCTest
@testable import ShiftoverProtocol

final class PhonePreferencesTests: XCTestCase {

    func testRoundTripAndReadOnlyPhoneMaySetItsOwn() throws {
        let method = RPCMethod.phonePreferences(update: .init(notificationKinds: [.done, .error],
                                                              liveActivity: .whenNeeded))
        XCTAssertFalse(method.isWrite, "a phone's own delivery is not an action on the Mac")
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        let read = RPCMethod.phonePreferences(update: nil)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(read)), read)
        let result = RPCResult.phonePreferences(.init(preferences: .init(), macNotificationKinds: [.input, .permission]))
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
    }

    func testGuestsCannotReachIt() {
        XCTAssertEqual(RPCMethod.phonePreferences(update: nil).guestScope, .denied)
    }

    /// A kind or mode from a newer build is dropped, not fatal: the rest of
    /// the record still applies.
    func testUnknownValuesDecodeLeniently() throws {
        let json = Data(#"{"notificationKinds":["done","somethingNew"],"liveActivity":"onTuesdays"}"#.utf8)
        let decoded = try JSONDecoder().decode(PhonePreferencesDTO.self, from: json)
        XCTAssertEqual(decoded.notificationKinds, [.done])
        XCTAssertEqual(decoded.liveActivity, .whileWorking)
        XCTAssertEqual(try JSONDecoder().decode(PhonePreferencesDTO.self, from: Data("{}".utf8)), .init())
    }

    func testNilKindsFollowTheMac() {
        let following = PhonePreferencesDTO()
        XCTAssertTrue(following.wants(.input, macKinds: [.input]))
        XCTAssertFalse(following.wants(.done, macKinds: [.input]))
        let own = PhonePreferencesDTO(notificationKinds: [.done])
        XCTAssertTrue(own.wants(.done, macKinds: []))
        XCTAssertFalse(own.wants(.input, macKinds: [.input]), "an empty-of-input choice overrides the Mac")
        let state = PhonePreferencesStateDTO(preferences: following, macNotificationKinds: [.permission])
        XCTAssertEqual(state.effectiveNotificationKinds, [.permission])
    }

    func testLiveActivityModes() {
        let working = AgentsActivityContent(macName: "Mac", agents: [agent(.working)], limit: nil, sentAt: Date())
        let asking = AgentsActivityContent(macName: "Mac", agents: [agent(.working), agent(.permission)],
                                           limit: nil, sentAt: Date())
        let quiet = AgentsActivityContent(macName: "Mac", agents: [], limit: nil, sentAt: Date())
        XCTAssertTrue(PhonePreferencesDTO(liveActivity: .whileWorking).showsLiveActivity(working))
        XCTAssertFalse(PhonePreferencesDTO(liveActivity: .whenNeeded).showsLiveActivity(working))
        XCTAssertTrue(PhonePreferencesDTO(liveActivity: .whenNeeded).showsLiveActivity(asking))
        XCTAssertFalse(PhonePreferencesDTO(liveActivity: .never).showsLiveActivity(asking))
        XCTAssertFalse(PhonePreferencesDTO(liveActivity: .whileWorking).showsLiveActivity(quiet))
    }

    func testCapabilityIsKnown() throws {
        let data = try JSONEncoder().encode([Capability.phonePreferences])
        XCTAssertEqual(try JSONDecoder().decode([Capability].self, from: data), [.phonePreferences])
    }

    private func agent(_ status: AgentStatusDTO) -> AgentsActivityContent.Agent {
        .init(worktreeID: UUID(), paneID: nil, project: "p", branch: "b", agent: nil, status: status, since: Date())
    }
}

final class PhonePreferencesUsageWidgetTests: XCTestCase {
    /// An update without the flag keeps the stored one: an older phone, or a
    /// settings edit made from a stale copy, must not stop usage pushes.
    func testAnUpdateWithoutTheFlagKeepsIt() throws {
        let stored = PhonePreferencesDTO(liveActivity: .whileWorking, usageWidget: true)
        XCTAssertEqual(stored.applying(PhonePreferencesDTO(liveActivity: .never)).usageWidget, true)
        XCTAssertEqual(stored.applying(PhonePreferencesDTO(liveActivity: .never)).liveActivity, .never)
        XCTAssertEqual(stored.applying(PhonePreferencesDTO(usageWidget: false)).usageWidget, false)
    }

    func testTheFlagRoundTripsAndOlderRecordsDecode() throws {
        let encoded = try JSONEncoder().encode(PhonePreferencesDTO(usageWidget: true))
        XCTAssertEqual(try JSONDecoder().decode(PhonePreferencesDTO.self, from: encoded).usageWidget, true)
        let older = try JSONDecoder().decode(PhonePreferencesDTO.self, from: Data(#"{"liveActivity":"never"}"#.utf8))
        XCTAssertNil(older.usageWidget)
        let odd = try JSONDecoder().decode(PhonePreferencesDTO.self, from: Data(#"{"usageWidget":"yes"}"#.utf8))
        XCTAssertNil(odd.usageWidget)
    }
}
