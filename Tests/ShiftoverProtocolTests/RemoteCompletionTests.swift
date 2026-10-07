import XCTest
@testable import ShiftoverProtocol

final class RemoteCompletionTests: XCTestCase {
    func testWorktreeFileSuggestionsAreReadOnlyAndRoundTrip() throws {
        let method = RPCMethod.listWorktreeFiles(worktreeID: UUID(), query: "Sources/App")
        XCTAssertFalse(method.isWrite)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        let result = RPCResult.worktreeFiles(["Sources/App.swift", "Docs/My Notes.md"])
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
    }

    func testTaskStartRoundTripsAndRequiresWrite() throws {
        let method = RPCMethod.kickoffTask(projectID: UUID(), prompt: "Fix tests", agent: .codex, baseBranch: nil)
        XCTAssertTrue(method.isWrite)
        XCTAssertFalse(RPCMethod.terminalSnapshot(paneID: UUID()).isWrite)
        XCTAssertFalse(RPCMethod.reviewDetails(worktreeID: UUID()).isWrite)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        let result = RPCResult.taskStarted(worktreeID: UUID())
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
    }

    func testWithdrawalFlagIsAuthenticatedAndOldPayloadStillDecodes() throws {
        let mac = RemoteIdentityKey(), phone = RemoteIdentityKey()
        let content = PushContent(kind: .done, worktreeID: UUID(), title: "", subtitle: nil,
                                  body: "", withdrawn: true)
        let box = try PushSealing.seal(content, toPhoneKey: phone.publicKeyData, from: mac)
        XCTAssertEqual(PushSealing.open(box, with: phone, fromAnyOf: [mac.publicKeyData])?.content, content)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        json.removeValue(forKey: "withdrawn")
        XCTAssertNil(try JSONDecoder().decode(PushContent.self, from: JSONSerialization.data(withJSONObject: json)).withdrawn)
    }

    func testFutureDatedPushCannotExtendReplayWindow() throws {
        let mac = RemoteIdentityKey(), phone = RemoteIdentityKey(), now = Date()
        let future = PushContent(kind: .permission, worktreeID: UUID(), title: "x", subtitle: nil,
                                 body: "x", sentAt: now.addingTimeInterval(120))
        let box = try PushSealing.seal(future, toPhoneKey: phone.publicKeyData, from: mac)
        XCTAssertNil(PushSealing.open(box, with: phone, fromAnyOf: [mac.publicKeyData], now: now))
    }
}
