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
             .requestDrive(let id), .releaseDrive(let id), .closeSharedTerminal(let id),
             .fitSharedTerminal(let id, _, _): return .pane(id)
        case .reportFocus(let id): return id.map(GuestMethodScope.pane) ?? .connection
        case .provePresence, .registerCollaborator, .requestRelayPass: return .connection
        // A new terminal in the shared project, for someone who may drive;
        // the host asks its user first (or not, for a collaborator it lets
        // drive without asking).
        case .createTerminalTab(let id, _), .createAgentTab(let id, _, _, _): return .worktree(id)
        case .agentQuestions, .answerAgentQuestion, .agentInsights, .providerUsage,
             .gitMutate, .beginAttachment, .appendAttachment,
             .finishAttachment, .cancelAttachment, .notificationPresence,
             .agentPaneAction, .renameAgentTab, .fleetSummary,
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
