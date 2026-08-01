import Foundation

// MARK: - Wire DTOs
//
// PLAN_45 D7: these deliberately MIRROR the desktop's domain model rather than
// being it. `Project` / `Worktree` / `Pane` carry persistence semantics,
// filesystem URLs and migration history that have no business on a phone — and
// keeping them separate means a `PersistedState` schema bump can never force an
// App Store release (nor a wire change force a state.json migration).
//
// Rule: every field here must be something the PHONE actually renders or acts
// on. If Go has no use for it, it does not belong on the wire.

/// Mirrors the desktop's 7-case `AgentStatus`.
public enum AgentStatusDTO: String, Codable, Sendable, Equatable {
    case idle        // faint grey — nothing running
    case present     // white solid — an agent CLI is running
    case working     // white pulsing — actively producing output
    case input       // yellow — waiting for input
    case permission  // orange — waiting for approval
    case done        // green
    case error       // red

    /// Whether this status is one a human needs to resolve. Drives which rows
    /// float to the top of the fleet list and which transitions earn a push.
    public var needsAttention: Bool {
        self == .input || self == .permission || self == .error
    }
}

/// The agent CLIs a task can be queued against.
public enum AgentKindDTO: String, Codable, Sendable, Equatable, CaseIterable {
    case claude, codex, gemini, copilot, opencode
}

public struct ProjectDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    /// Non-git (plain directory) projects hide git-only affordances in Go, the
    /// same way the desktop gates on `Project.isGit`.
    public let isGit: Bool

    public init(id: UUID, name: String, isGit: Bool) {
        self.id = id
        self.name = name
        self.isGit = isGit
    }
}

public struct WorktreeDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let branch: String
    public let isMain: Bool
    public let agentStatus: AgentStatusDTO
    public let baseBranch: String?
    /// Newest agent message seen for this worktree — the push body, and the
    /// subtitle in the fleet list.
    public let lastAgentMessage: String?

    public init(id: UUID, projectID: UUID, branch: String, isMain: Bool,
                agentStatus: AgentStatusDTO, baseBranch: String?,
                lastAgentMessage: String?) {
        self.id = id
        self.projectID = projectID
        self.branch = branch
        self.isMain = isMain
        self.agentStatus = agentStatus
        self.baseBranch = baseBranch
        self.lastAgentMessage = lastAgentMessage
    }
}

public struct PaneDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Raw `PaneType` value. A string, not an enum, precisely so a desktop that
    /// gains a new pane type does not break an older Go — it renders as an
    /// unknown/unsupported row instead (D16, additively ignorable).
    public let type: String
    public let title: String
    /// True for a `.terminal` pane that can be attached to for live streaming.
    public let isStreamable: Bool

    public init(id: UUID, type: String, title: String, isStreamable: Bool) {
        self.id = id
        self.type = type
        self.title = title
        self.isStreamable = isStreamable
    }
}

/// The one-line cross-section the desktop already computes for the Fleet pane
/// toolbar (`AppState.fleetSummary`), e.g. "2 queued · 3 working · 1 to review".
public struct FleetSummaryDTO: Codable, Sendable, Hashable {
    public let queued: Int
    public let working: Int
    public let toReview: Int

    public init(queued: Int, working: Int, toReview: Int) {
        self.queued = queued
        self.working = working
        self.toReview = toReview
    }
}

public struct ReviewItemDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { worktreeID }
    public let worktreeID: UUID
    public let projectName: String
    public let branch: String
    public let commitsAhead: Int
    public let changedFiles: Int
    /// Approve & merge is gated on a clean tree — the desktop refuses otherwise,
    /// so Go must render the same gate rather than offering a doomed button.
    public let isClean: Bool
    public let lastAgentMessage: String?

    public init(worktreeID: UUID, projectName: String, branch: String,
                commitsAhead: Int, changedFiles: Int, isClean: Bool,
                lastAgentMessage: String?) {
        self.worktreeID = worktreeID
        self.projectName = projectName
        self.branch = branch
        self.commitsAhead = commitsAhead
        self.changedFiles = changedFiles
        self.isClean = isClean
        self.lastAgentMessage = lastAgentMessage
    }
}

/// A trimmed projection of the desktop's `MonitorSnapshot` — the numbers that
/// fit a phone screen, not the whole cockpit (composition bar, pulse sparkline
/// and timeline stay desktop-only for now).
public struct MonitorSummaryDTO: Codable, Sendable, Hashable {
    public let agent: String          // "claude" | "codex"
    public let model: String          // display name, e.g. "Opus 5"
    public let contextUsed: Int
    public let contextLimit: Int
    public let estimatedCostUSD: Double
    public let promptCount: Int

    public init(agent: String, model: String, contextUsed: Int,
                contextLimit: Int, estimatedCostUSD: Double, promptCount: Int) {
        self.agent = agent
        self.model = model
        self.contextUsed = contextUsed
        self.contextLimit = contextLimit
        self.estimatedCostUSD = estimatedCostUSD
        self.promptCount = promptCount
    }

    /// 0...1, clamped. `0` when the limit is unknown rather than dividing by zero.
    public var contextFraction: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, max(0, Double(contextUsed) / Double(contextLimit)))
    }
}
