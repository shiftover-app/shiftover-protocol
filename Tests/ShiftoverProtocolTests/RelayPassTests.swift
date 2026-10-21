import XCTest
@testable import ShiftoverProtocol

final class RelayPassTests: XCTestCase {
    /// The same vector the relay's own test checks, so the two sides agree.
    func testMintMatchesTheRelaysVector() throws {
        let pass = try XCTUnwrap(RelayPass.mint(accessKey: "test-access-key", id: "abc-123",
                                                expiresAt: Date(timeIntervalSince1970: 2_000_000_000)))
        XCTAssertEqual(pass.token, "pass.v1.2000000000.abc-123.JL-eeZKP-U8TMOaaZBC5zg5HqrcMvsCvzeR7ZVYTl9g")
        XCTAssertEqual(pass.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testRefusesAnIDThatWouldBreakTheFormat() {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNil(RelayPass.mint(accessKey: "k", id: "a.b", expiresAt: expiry))
        XCTAssertNil(RelayPass.mint(accessKey: "k", id: "", expiresAt: expiry))
        XCTAssertNil(RelayPass.mint(accessKey: "", id: "abc", expiresAt: expiry))
        XCTAssertNotNil(RelayPass.mint(accessKey: "k", id: UUID().uuidString, expiresAt: expiry))
    }

    func testGuestsMayAskForTerminalsAndCloseThem() {
        let worktree = UUID(), pane = UUID()
        XCTAssertEqual(RPCMethod.createTerminalTab(worktreeID: worktree, requestID: UUID()).guestScope, .worktree(worktree))
        XCTAssertEqual(RPCMethod.createAgentTab(worktreeID: worktree, agent: .claude, prompt: "", requestID: UUID()).guestScope,
                       .worktree(worktree))
        XCTAssertEqual(RPCMethod.closeSharedTerminal(paneID: pane).guestScope, .pane(pane))
        XCTAssertTrue(RPCMethod.closeSharedTerminal(paneID: pane).isWrite)
        XCTAssertEqual(RPCMethod.requestRelayPass.guestScope, .connection)
        XCTAssertFalse(RPCMethod.requestRelayPass.isWrite)
    }
}
