import XCTest
@testable import ShiftoverProtocol

final class ProjectWorkspaceTests: XCTestCase {
    func testLegacyWorkspaceStillDecodesAndNewPanesRoundTrip() throws {
        let legacy = WorkspaceDTO(projects: [], worktrees: [], tabs: [], availableAgents: [])
        XCTAssertNil(try JSONDecoder().decode(WorkspaceDTO.self, from: JSONEncoder().encode(legacy)).allTabs)
        var modern = legacy
        modern.allTabs = [WorkspaceTabDTO(id: UUID(), projectID: UUID(), worktreeID: UUID(), title: "Build", panes: [
            WorkspacePaneDTO(id: UUID(), type: "terminal", title: "zsh", isStreamable: true),
            WorkspacePaneDTO(id: UUID(), type: "future-kind", title: "Future", isStreamable: false)])]
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceDTO.self, from: JSONEncoder().encode(modern)), modern)
    }

    func testGitReadsAreReadOnlyAndRoundTrip() throws {
        for method: RPCMethod in [.gitSnapshot(worktreeID: UUID()), .gitFileDiff(worktreeID: UUID(), path: "a file.swift", scope: .staged)] {
            XCTAssertFalse(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
    }

    func testConflictsAndMixedStateAreNotMislabelled() {
        for pair in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            let file = GitFileStatusDTO(path: "a", indexStatus: String(pair.first!), worktreeStatus: String(pair.last!))
            XCTAssertTrue(file.isConflicted)
            XCTAssertFalse(file.isStaged)
        }
        let file = GitFileStatusDTO(path: "a", indexStatus: "M", worktreeStatus: "M")
        XCTAssertTrue(file.isStaged); XCTAssertTrue(file.isUnstaged)
        let untracked = GitFileStatusDTO(path: "b", indexStatus: "?", worktreeStatus: "?")
        XCTAssertTrue(untracked.isUntracked); XCTAssertFalse(untracked.isStaged)
    }
}
