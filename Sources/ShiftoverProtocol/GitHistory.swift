import Foundation

public struct GitBranchDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String { ref }
    public let ref: String
    public let name: String
    public let isRemote: Bool
    public init(ref: String, name: String, isRemote: Bool) {
        self.ref = ref; self.name = name; self.isRemote = isRemote
    }
}

public struct GitBranchesDTO: Codable, Sendable, Equatable {
    public let branches: [GitBranchDTO]
    public let truncated: Bool
    public init(branches: [GitBranchDTO], truncated: Bool = false) {
        self.branches = branches; self.truncated = truncated
    }
}

public struct GitChangedFileDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let status: String
    public init(path: String, originalPath: String? = nil, status: String) {
        self.path = path; self.originalPath = originalPath; self.status = status
    }
}

public struct GitCommitDetailsDTO: Codable, Sendable, Equatable {
    public let commit: GitCommitDTO
    public let message: String
    public let parents: [String]
    /// Merge commits are compared with their first parent.
    public let files: [GitChangedFileDTO]
    public let truncated: Bool
    public init(commit: GitCommitDTO, message: String, parents: [String], files: [GitChangedFileDTO], truncated: Bool = false) {
        self.commit = commit; self.message = message; self.parents = parents
        self.files = files; self.truncated = truncated
    }
}

public struct GitComparisonDTO: Codable, Sendable, Equatable {
    public let baseRef: String
    public let baseHash: String
    public let headHash: String
    public let mergeBaseHash: String
    /// Commits reachable from HEAD but not the selected base (latest 50).
    public let commits: [GitCommitDTO]
    public let commitCount: Int
    /// Changes from the shared ancestor to HEAD, excluding working-tree edits.
    public let files: [GitChangedFileDTO]
    public let truncated: Bool
    public init(baseRef: String, baseHash: String, headHash: String, mergeBaseHash: String,
                commits: [GitCommitDTO], commitCount: Int, files: [GitChangedFileDTO], truncated: Bool = false) {
        self.baseRef = baseRef; self.baseHash = baseHash; self.headHash = headHash
        self.mergeBaseHash = mergeBaseHash; self.commits = commits; self.commitCount = commitCount
        self.files = files; self.truncated = truncated
    }
}
