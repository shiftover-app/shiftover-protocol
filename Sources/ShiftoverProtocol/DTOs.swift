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

// MARK: - Conversations
//
// A conversation is ONE agent session — one Claude Code / Codex CLI transcript
// on disk. That equivalence is the whole design: the agents already write a
// structured, append-only JSONL record of every prompt, reply, thinking block
// and tool call, so the phone can render a real message thread without anyone
// parsing terminal output.
//
// ⚠️ **Not parsed from the terminal, deliberately.** Reconstructing messages by
// scraping a TUI's ANSI output is the approach that has been tried and does not
// hold up — an agent repaints, rewrites lines, animates spinners and truncates
// to the pty width, so the "message" you recover is a rendering artefact rather
// than what the agent said. The transcript is the agent's own record: exact,
// already segmented, and stable.
//
// The consequence worth stating up front: **only agents that write a parseable
// transcript can be conversations.** Claude Code and Codex CLI do; Gemini,
// Copilot and OpenCode do not, so they have no conversation and the phone falls
// back to their terminal. That is a real gap, not an oversight — it is better
// than inventing messages for them.

/// Which agent wrote a transcript. Narrower than `AgentKindDTO` on purpose:
/// this is "agents whose sessions can be read", not "agents that can be run".
public enum ConversationAgentDTO: String, Codable, Sendable, Equatable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

/// One agent session, as a conversation.
public struct ConversationDTO: Codable, Sendable, Hashable, Identifiable {
    /// Stable, opaque, and **derived from the transcript's path** rather than
    /// minted per connection — so a phone that reconnects, or relaunches, still
    /// addresses the same conversation without the desktop keeping a registry
    /// that could drift. Deliberately not the path itself: absolute filesystem
    /// paths are the user's business and have no reason to cross the wire.
    public let id: UUID
    public let worktreeID: UUID
    public let projectID: UUID
    public let agent: ConversationAgentDTO
    /// Branch the session is running against — the primary label, because that
    /// is how the desktop identifies a worktree too.
    public let branch: String
    public let projectName: String
    /// First user prompt, trimmed. The closest thing a session has to a title,
    /// and the only part a human recognises a week later.
    public let title: String?
    /// Model display name of the most recent turn ("Opus 5").
    public let model: String?
    /// Rendered agent status for the owning worktree — lets the list show a
    /// live dot without a second round trip.
    public let status: AgentStatusDTO
    public let messageCount: Int
    public let lastActivityAt: Date?
    /// Whether this is the worktree's CURRENT session (the one an agent is
    /// appending to), as opposed to an earlier session still on disk.
    public let isLive: Bool

    public init(id: UUID, worktreeID: UUID, projectID: UUID,
                agent: ConversationAgentDTO, branch: String, projectName: String,
                title: String?, model: String?, status: AgentStatusDTO,
                messageCount: Int, lastActivityAt: Date?, isLive: Bool) {
        self.id = id
        self.worktreeID = worktreeID
        self.projectID = projectID
        self.agent = agent
        self.branch = branch
        self.projectName = projectName
        self.title = title
        self.model = model
        self.status = status
        self.messageCount = messageCount
        self.lastActivityAt = lastActivityAt
        self.isLive = isLive
    }
}

/// What kind of thing was said. Mirrors the desktop's
/// `MonitorTimelineEntry.Kind`, with `command` split out of `prompt` because a
/// slash command is not something the user *said* and should not render as a
/// message bubble.
public enum MessageRoleDTO: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case thinking
    case tool
    case command
}

/// One message in a conversation.
public struct AgentMessageDTO: Codable, Sendable, Hashable, Identifiable {
    /// The transcript's own `uuid` (plus a block-index suffix when one
    /// transcript record yields several messages), so identity is stable across
    /// re-reads and an append never renumbers what is already on screen.
    public let id: String
    public let timestamp: Date
    public let role: MessageRoleDTO
    /// Leading label — "Prompt" / "Response" / "Thinking" / the tool's name.
    public let title: String
    /// Single-line preview. For a tool call, a summary of its input.
    public let text: String?
    /// The fuller body, revealed on expansion. `nil` when there is nothing more
    /// than `text`. Clipped by the desktop so one enormous tool result cannot
    /// dominate a response.
    public let expanded: String?
    /// Estimated tokens attributed to this message; for a tool call, the size
    /// of its *result* — what actually lands in context.
    public let tokens: Int?

    public init(id: String, timestamp: Date, role: MessageRoleDTO, title: String,
                text: String?, expanded: String?, tokens: Int?) {
        self.id = id
        self.timestamp = timestamp
        self.role = role
        self.title = title
        self.text = text
        self.expanded = expanded
        self.tokens = tokens
    }
}

/// A page of messages, oldest → newest (reading order).
public struct ConversationMessagesDTO: Codable, Sendable, Hashable {
    public let conversationID: UUID
    public let messages: [AgentMessageDTO]
    /// `true` when the desktop is holding a bounded window and older messages
    /// exist on disk that were not sent.
    ///
    /// Stated explicitly rather than left to be inferred from a short list: a
    /// thread that silently begins in the middle reads as data loss, and the
    /// phone can say "earlier messages aren't loaded" only if it is told.
    public let hasOlder: Bool

    public init(conversationID: UUID, messages: [AgentMessageDTO], hasOlder: Bool) {
        self.conversationID = conversationID
        self.messages = messages
        self.hasOlder = hasOlder
    }
}
