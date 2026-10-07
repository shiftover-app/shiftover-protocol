import XCTest
@testable import ShiftoverProtocol

final class ProjectWorkspaceTests: XCTestCase {
    func testImagePreviewCompatibilityAndRoundTrip() throws {
        let old = Data(#"{"text":"old","isBinary":false,"truncated":false}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceFileContent.self, from: old)
        XCTAssertNil(decoded.image); XCTAssertNil(decoded.previewNote)
        let image = WorkspaceImagePreview(data: Data([0, 1, 2]), mediaType: "image/png",
            width: 32, height: 24, originalWidth: 64, originalHeight: 48, isAnimated: true)
        let content = WorkspaceFileContent(text: "", isBinary: true, image: image)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceFileContent.self, from: JSONEncoder().encode(content)), content)
        struct Legacy: Decodable { let text: String; let isBinary: Bool; let truncated: Bool }
        XCTAssertTrue(try JSONDecoder().decode(Legacy.self, from: JSONEncoder().encode(content)).isBinary)
        XCTAssertFalse(RPCMethod.readWorkspaceFile(worktreeID: UUID(), path: "photo.png").isWrite)
    }

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
