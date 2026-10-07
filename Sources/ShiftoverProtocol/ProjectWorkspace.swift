import Foundation

/// Desktop order and tab grouping are preserved; unknown pane kinds stay visible.
public struct WorkspaceTabDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let worktreeID: UUID
    public let title: String
    public let panes: [WorkspacePaneDTO]
    public init(id: UUID, projectID: UUID, worktreeID: UUID, title: String, panes: [WorkspacePaneDTO]) {
        self.id = id; self.projectID = projectID; self.worktreeID = worktreeID
        self.title = title; self.panes = panes
    }
}

public struct WorkspacePaneDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let type: String
    public let title: String
    public let isStreamable: Bool
    public let agent: AgentPaneDTO?
    public init(id: UUID, type: String, title: String, isStreamable: Bool, agent: AgentPaneDTO? = nil) {
        self.id = id; self.type = type; self.title = title
        self.isStreamable = isStreamable; self.agent = agent
    }
}

public enum GitDiffScope: String, Codable, Sendable, CaseIterable {
    case staged, unstaged, untracked
}

public struct GitFileStatusDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let indexStatus: String?
    public let worktreeStatus: String?
    public var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
    public var isConflicted: Bool {
        indexStatus == "U" || worktreeStatus == "U" || (indexStatus == "A" && worktreeStatus == "A") || (indexStatus == "D" && worktreeStatus == "D")
    }
    public var isStaged: Bool { indexStatus != nil && !isUntracked && !isConflicted }
    public var isUnstaged: Bool { worktreeStatus != nil && !isUntracked && !isConflicted }
    public init(path: String, originalPath: String? = nil, indexStatus: String?, worktreeStatus: String?) {
        self.path = path; self.originalPath = originalPath
        self.indexStatus = indexStatus; self.worktreeStatus = worktreeStatus
    }
}

public struct GitCommitDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let author: String
    public let date: Date
    public init(hash: String, shortHash: String, subject: String, author: String, date: Date) {
        self.hash = hash; self.shortHash = shortHash; self.subject = subject; self.author = author; self.date = date
    }
}

public struct GitSnapshotDTO: Codable, Sendable, Equatable {
    public let branch: String?
    public let upstream: String?
    /// nil when no upstream is configured or its comparison could not be read.
    public let ahead: Int?
    public let behind: Int?
    public let files: [GitFileStatusDTO]
    public let commits: [GitCommitDTO]
    /// A bounded status list must never masquerade as a complete clean tree.
    public let truncated: Bool
    public let capturedAt: Date
    public init(branch: String?, upstream: String?, ahead: Int?, behind: Int?, files: [GitFileStatusDTO], commits: [GitCommitDTO], truncated: Bool = false, capturedAt: Date = Date()) {
        self.branch = branch; self.upstream = upstream; self.ahead = ahead; self.behind = behind
        self.files = files; self.commits = commits; self.truncated = truncated; self.capturedAt = capturedAt
    }
}

public struct GitFileDiffDTO: Codable, Sendable, Equatable {
    public let text: String
    public let truncated: Bool
    public let isBinary: Bool
    public init(text: String, truncated: Bool = false, isBinary: Bool = false) {
        self.text = text; self.truncated = truncated; self.isBinary = isBinary
    }
}
