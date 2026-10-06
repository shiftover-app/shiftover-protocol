import XCTest
@testable import ShiftoverProtocol

final class WorkspaceTests: XCTestCase {
    func testWorkspacePreservesDistinctAgentsInOneWorktree() throws {
        let project = UUID(), worktree = UUID()
        let panes = ["first", "second"].map { session in
            AgentPaneDTO(id: UUID(), title: session, agent: .claude, status: .working,
                         conversationID: UUID(), sessionID: session, isRunning: true)
        }
        let workspace = WorkspaceDTO(projects: [], worktrees: [], tabs: panes.map {
            AgentTabDTO(id: UUID(), projectID: project, worktreeID: worktree, title: $0.title, panes: [$0])
        }, availableAgents: [.claude])
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceDTO.self, from: JSONEncoder().encode(workspace)), workspace)
        XCTAssertNotEqual(workspace.tabs[0].panes[0].id, workspace.tabs[1].panes[0].id)
    }

    func testEveryWorkspaceMutationIsWriteGatedAndRoundTrips() throws {
        let methods: [RPCMethod] = [
            .createAgentTab(worktreeID: UUID(), agent: .codex, prompt: "Fix tests", requestID: UUID()),
            .agentPaneAction(paneID: UUID(), sessionID: "session-a", action: .send(text: "continue")),
            .agentPaneAction(paneID: UUID(), sessionID: "session-b", action: .interrupt),
            .agentPaneAction(paneID: UUID(), sessionID: "session-c", action: .permission(allow: false)),
            .renameAgentTab(tabID: UUID(), title: "Fix tests")]
        for method in methods {
            XCTAssertTrue(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
        XCTAssertFalse(RPCMethod.workspace.isWrite)
    }

    func testOlderProjectStillDecodes() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"name\":\"App\",\"isGit\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ProjectDTO.self, from: data).groupName)
    }
}
