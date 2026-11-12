import XCTest
@testable import ShiftoverProtocol

final class WorkspaceTests: XCTestCase {
    func testActivityRoundTripsAndDecodesFromOlderOrNewerHosts() throws {
        let pane = AgentPaneDTO(id: UUID(), title: "a", agent: .claude, status: .working,
                                conversationID: nil, sessionID: nil, isRunning: true, activity: .waitingOnShell)
        XCTAssertEqual(try JSONDecoder().decode(AgentPaneDTO.self, from: JSONEncoder().encode(pane)).activity, .waitingOnShell)

        // An older host sends no key; a newer one may send a kind this build
        // does not know. Neither may fail the decode.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pane)) as! [String: Any]
        object["activity"] = nil
        XCTAssertNil(try JSONDecoder().decode(AgentPaneDTO.self, from: JSONSerialization.data(withJSONObject: object)).activity)
        object["activity"] = "summarizing"
        XCTAssertEqual(try JSONDecoder().decode(AgentPaneDTO.self, from: JSONSerialization.data(withJSONObject: object)).activity?.rawValue, "summarizing")

        let worktree = WorktreeDTO(id: UUID(), projectID: UUID(), branch: "main", isMain: true, agentStatus: .working,
                                   baseBranch: nil, lastAgentMessage: nil, activity: .compacting)
        XCTAssertEqual(try JSONDecoder().decode(WorktreeDTO.self, from: JSONEncoder().encode(worktree)), worktree)
    }

    func testActivityRollupNeedsEveryWorkingSessionToAgree() {
        typealias Entry = (status: AgentStatusDTO, activity: AgentActivityDTO?)
        let shell: Entry = (.working, .waitingOnShell)
        let compacting: Entry = (.working, .compacting)
        let working: Entry = (.working, nil)
        XCTAssertEqual(AgentActivityDTO.rollup([shell, (.present, nil), (.done, nil)]), .waitingOnShell)
        XCTAssertEqual(AgentActivityDTO.rollup([compacting, compacting]), .compacting)
        XCTAssertNil(AgentActivityDTO.rollup([shell, working]))
        XCTAssertNil(AgentActivityDTO.rollup([shell, compacting]))
        // A question outranks work: the row is not working at all.
        XCTAssertNil(AgentActivityDTO.rollup([shell, (.input, nil)]))
        XCTAssertNil(AgentActivityDTO.rollup([Entry]()))
    }

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
            .agentPaneAction(paneID: UUID(), sessionID: nil, action: .answerStartupPrompt(promptID: "question", option: 1)),
            .renameAgentTab(tabID: UUID(), title: "Fix tests")]
        for method in methods {
            XCTAssertTrue(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
        XCTAssertFalse(RPCMethod.workspace.isWrite)
    }

    func testStartupQuestionAndLegacyPaneDecode() throws {
        let prompt = AgentStartupPromptDTO(id: "question", directory: "/project", options: ["No, exit", "Yes, I trust this folder"])
        var pane = AgentPaneDTO(id: UUID(), title: "Test", agent: .claude, status: .input,
            conversationID: nil, sessionID: nil, isRunning: true, startupPrompt: prompt)
        XCTAssertEqual(try JSONDecoder().decode(AgentPaneDTO.self, from: JSONEncoder().encode(pane)), pane)
        pane.startupPrompt = nil
        let legacy = try JSONEncoder().encode(pane)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("startupPrompt"))
        XCTAssertNil(try JSONDecoder().decode(AgentPaneDTO.self, from: legacy).startupPrompt)
    }

    func testOlderProjectStillDecodes() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"name\":\"App\",\"isGit\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ProjectDTO.self, from: data).groupName)
    }
}
