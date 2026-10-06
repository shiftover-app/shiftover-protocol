import Foundation

/// Desktop workspace order, independent of transcript history and window focus.
public struct WorkspaceDTO: Codable, Sendable, Equatable {
    public var projects: [ProjectDTO]
    public var worktrees: [WorktreeDTO]
    public var tabs: [AgentTabDTO]
    public var conversations: [ConversationDTO]
    public var availableAgents: [AgentKindDTO]
    public init(projects: [ProjectDTO], worktrees: [WorktreeDTO], tabs: [AgentTabDTO], conversations: [ConversationDTO] = [], availableAgents: [AgentKindDTO]) {
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

public struct AgentPaneDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var agent: AgentKindDTO
    public var status: AgentStatusDTO
    public var conversationID: UUID?
    public var sessionID: String?
    public var isRunning: Bool
    public init(id: UUID, title: String, agent: AgentKindDTO, status: AgentStatusDTO,
                conversationID: UUID?, sessionID: String?, isRunning: Bool) {
        self.id = id; self.title = title; self.agent = agent; self.status = status
        self.conversationID = conversationID; self.sessionID = sessionID; self.isRunning = isRunning
    }
}

public enum AgentPaneAction: Codable, Sendable, Equatable {
    case send(text: String)
    case interrupt
    case permission(allow: Bool)
}

extension AgentStatusDTO {
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
