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

    func testWorkspaceActionsRoundTripAndRequireWriteGrant() throws {
        let id = UUID()
        let actions: [WorkspaceGitAction] = [.stage(path: "a [b]"), .unstage(path: "a"), .commit(message: "A commit"), .push, .pull]
        for method in actions.map({ RPCMethod.gitMutate(worktreeID: id, action: $0, expectedRevision: "sha", requestID: UUID()) }) + [.createTerminalTab(worktreeID: id, requestID: UUID())] {
            XCTAssertTrue(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
        for method: RPCMethod in [.browseDirectory(worktreeID: id, path: ""), .readWorkspaceFile(worktreeID: id, path: "README.md")] {
            XCTAssertFalse(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
        let legacy = GitSnapshotDTO(branch: "main", upstream: nil, ahead: nil, behind: nil, files: [], commits: [])
        XCTAssertNil(try JSONDecoder().decode(GitSnapshotDTO.self, from: JSONEncoder().encode(legacy)).revision)
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
