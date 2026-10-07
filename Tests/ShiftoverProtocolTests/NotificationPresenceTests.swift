import XCTest
@testable import ShiftoverProtocol

final class NotificationPresenceTests: XCTestCase {
    func testRoundTripAndReadOnlyDeviceMaySetOwnDelivery() throws {
        let method = RPCMethod.notificationPresence(mode: .automatic, rssi: -64)
        XCTAssertFalse(method.isWrite)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        let result = RPCResult.notificationPresence(.init(mode: .automatic, isAway: true,
            source: .bluetooth, bluetoothServiceID: UUID()))
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
    }
    func testManualOverridesAndAutomaticDelivery() {
        for away in [false, true] {
            XCTAssertTrue(NotificationPresenceDTO(mode: .always, isAway: away, source: .macActivity).notificationsEnabled)
            XCTAssertFalse(NotificationPresenceDTO(mode: .muted, isAway: away, source: .macActivity).notificationsEnabled)
            XCTAssertEqual(NotificationPresenceDTO(mode: .automatic, isAway: away, source: .macActivity).notificationsEnabled, away)
        }
    }
}
