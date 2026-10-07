import XCTest
@testable import ShiftoverProtocol

final class GitHistoryTests: XCTestCase {
    func testHistoryRequestsRoundTripAndRemainReadOnly() throws {
        let id = UUID()
        for method in [RPCMethod.gitBranches(worktreeID: id), .gitCompare(worktreeID: id, baseRef: "refs/heads/main"),
                       .gitCommitDetails(worktreeID: id, hash: "abc"), .gitRevisionDiff(worktreeID: id, baseHash: nil, headHash: "abc", path: "a\nb")] {
            XCTAssertFalse(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
    }
    func testHistoryResultsRoundTrip() throws {
        let commit = GitCommitDTO(hash: "abc", shortHash: "abc", subject: "Title", author: "A", date: Date(timeIntervalSince1970: 100))
        let files = [GitChangedFileDTO(path: "new", originalPath: "old", status: "R100")]
        for result in [RPCResult.gitBranches(.init(branches: [.init(ref: "refs/heads/main", name: "main", isRemote: false)])),
                       .gitCommitDetails(.init(commit: commit, message: "Title\n\nBody", parents: [], files: files)),
                       .gitComparison(.init(baseRef: "refs/heads/main", baseHash: "a", headHash: "b", mergeBaseHash: "c", commits: [commit], commitCount: 80, files: files, truncated: true))] {
            XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
        }
    }
}
