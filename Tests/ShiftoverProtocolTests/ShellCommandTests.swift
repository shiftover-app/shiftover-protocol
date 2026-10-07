import XCTest
@testable import ShiftoverProtocol

final class ShellCommandTests: XCTestCase {
    func testCommandsRequireWriteAndSnapshotsDoNot() throws {
        let pane = UUID(), prompt = UUID()
        let method = RPCMethod.submitShellCommand(paneID: pane, promptID: prompt, command: "git status")
        XCTAssertTrue(method.isWrite)
        XCTAssertFalse(RPCMethod.shellSnapshot(paneID: pane).isWrite)
        let data = try JSONEncoder().encode(method)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: data), method)
    }
    func testShellSnapshotRoundTrip() throws {
        let result = RPCResult.shellSnapshot(ShellSnapshotDTO(state: .ready, promptID: UUID(),
            commands: [ShellCommandDTO(command: "printf hello", output: "hello", isTruncated: true)]))
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertEqual(try JSONDecoder().decode(Capability.self, from: Data("\"shellCommands\"".utf8)), .shellCommands)
    }
}
