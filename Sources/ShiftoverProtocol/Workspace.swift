import Foundation

/// Desktop workspace order, independent of transcript history and window focus.
public struct WorkspaceDTO: Codable, Sendable, Equatable {
    public var projects: [ProjectDTO]
    public var worktrees: [WorktreeDTO]
    public var tabs: [AgentTabDTO]
    public var conversations: [ConversationDTO]
    public var availableAgents: [AgentKindDTO]
    /// All desktop tabs, including non-agent panes. Absent on older hosts.
    public var allTabs: [WorkspaceTabDTO]?
    public init(projects: [ProjectDTO], worktrees: [WorktreeDTO], tabs: [AgentTabDTO], conversations: [ConversationDTO] = [], availableAgents: [AgentKindDTO], allTabs: [WorkspaceTabDTO]? = nil) {
        self.allTabs = allTabs
        self.conversations = conversations
        self.projects = projects; self.worktrees = worktrees; self.tabs = tabs; self.availableAgents = availableAgents
    }
}

public struct AgentTabDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var worktreeID: UUID
    public var title: String
    public var panes: [AgentPaneDTO]
    public init(id: UUID, projectID: UUID, worktreeID: UUID, title: String, panes: [AgentPaneDTO]) {
        self.id = id; self.projectID = projectID; self.worktreeID = worktreeID; self.title = title; self.panes = panes
    }
}

/// A question shown before a transcript exists. The opaque ID binds an answer
/// to the exact prompt observed on the Mac; it is not a reusable approval.
public struct AgentStartupPromptDTO: Codable, Sendable, Hashable {
    public var id: String
    public var directory: String
    public var options: [String]
    public init(id: String, directory: String, options: [String]) {
        self.id = id; self.directory = directory; self.options = options
    }
}

public struct AgentPaneDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var agent: AgentKindDTO
    public var status: AgentStatusDTO
    public var conversationID: UUID?
    public var sessionID: String?
    public var startupPrompt: AgentStartupPromptDTO?
    public var isRunning: Bool
    public init(id: UUID, title: String, agent: AgentKindDTO, status: AgentStatusDTO,
                conversationID: UUID?, sessionID: String?, isRunning: Bool, startupPrompt: AgentStartupPromptDTO? = nil) {
        self.startupPrompt = startupPrompt
        self.id = id; self.title = title; self.agent = agent; self.status = status
        self.conversationID = conversationID; self.sessionID = sessionID; self.isRunning = isRunning
    }
}

public enum AgentPaneAction: Codable, Sendable, Equatable {
    case answerStartupPrompt(promptID: String, option: Int)
    case send(text: String)
    case interrupt
    case permission(allow: Bool)
}

extension AgentStatusDTO {
    /// One status standing for several sessions — a worktree with two agents,
    /// a project with several worktrees.
    ///
    /// Not `salience`, which ranks a finished turn above a working one: right
    /// for picking which one session to open, wrong for a row that stands for
    /// all of them. One agent finishing while another is still at work is not
    /// a finished worktree. Anything waiting on the user still wins, then work
    /// in progress, then a finished turn's badge.
    public static func rollup<S: Sequence>(_ statuses: S) -> AgentStatusDTO where S.Element == AgentStatusDTO {
        statuses.max { $0.rollupRank < $1.rollupRank } ?? .idle
    }

    var rollupRank: Int {
        switch self {
        case .idle: return 0
        case .present: return 1
        case .done: return 2
        case .working: return 3
        case .input: return 4
        case .permission: return 5
        case .error: return 6
        }
    }

    /// Same priority as the Mac sidebar.
    public var salience: Int {
        switch self {
        case .idle: return 0
        case .present: return 1
        case .working: return 2
        case .done: return 3
        case .input: return 4
        case .permission: return 5
        case .error: return 6
        }
    }
}
