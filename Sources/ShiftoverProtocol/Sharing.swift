import Foundation

/// No local folder or executable command is represented in a shared layout.
public indirect enum WorkspaceLayoutDTO: Codable, Sendable, Hashable {
    case pane(UUID)
    case split(vertical: Bool, children: [WorkspaceLayoutDTO], weights: [Double])
}

/// An exhaustive classification: adding a verb forces a guest-access decision.
public enum GuestMethodScope: Equatable, Sendable {
    case denied
    case projectList
    case project(UUID?)
    case worktree(UUID)
    case pane(UUID)
    case connection
}

extension RPCMethod {
    public var guestScope: GuestMethodScope {
        switch self {
        case .workspace, .listProjects: return .projectList
        case .listWorktrees(let id): return .project(id)
        case .browseDirectory(let id, _), .readWorkspaceFile(let id, _),
             .gitBranches(let id), .gitCompare(let id, _), .gitCommitDetails(let id, _),
             .gitRevisionDiff(let id, _, _, _), .gitSnapshot(let id),
             .gitFileDiff(let id, _, _), .listPanes(let id), .listWorktreeFiles(let id, _):
            return .worktree(id)
        case .attachSharedTerminal(let id), .detachTerminal(let id),
             .requestDrive(let id), .releaseDrive(let id): return .pane(id)
        case .reportFocus(let id): return id.map(GuestMethodScope.pane) ?? .connection
        case .provePresence, .registerCollaborator: return .connection
        case .agentQuestions, .answerAgentQuestion, .agentInsights, .providerUsage,
             .createTerminalTab, .gitMutate, .beginAttachment, .appendAttachment,
             .finishAttachment, .cancelAttachment, .notificationPresence,
             .createAgentTab, .agentPaneAction, .renameAgentTab, .fleetSummary,
             .reviewItems, .monitorSummary, .reviewDetails, .listConversations,
             .conversationMessages, .unwatchConversation, .acknowledgeAgentStatus,
             .listSlashCommands, .replyToAgent, .answerPermission, .interruptAgent,
             .setAgentInput, .enqueueTask, .kickoffTask, .approveAndMerge,
             .createPullRequest, .requestChanges, .attachTerminal, .terminalSnapshot,
             .shellSnapshot, .submitShellCommand:
            return .denied
        }
    }
}
