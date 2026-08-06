import Foundation

// MARK: - RPC
//
// Request/response over `.request` / `.response` frames. Every method here maps
// onto a verb the DESKTOP ALREADY IMPLEMENTS — that is the whole reason the
// mobile app is tractable (PLAN_45): `replyToAgent`, `answerAgentPermission`,
// `enqueueTask`, `approveAndMergeReview`, `createReviewPR` and
// `requestReviewChanges` are written and hardened. Go is a second client for
// existing behaviour, not new behaviour.
//
// Correlation is an explicit `id` rather than ordering, because terminal bulk
// frames interleave freely with control frames on the same socket.

public struct RPCRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let method: RPCMethod

    public init(id: UUID = UUID(), method: RPCMethod) {
        self.id = id
        self.method = method
    }
}

public struct RPCResponse: Codable, Sendable, Equatable {
    public let id: UUID
    public let result: RPCResult

    public init(id: UUID, result: RPCResult) {
        self.id = id
        self.result = result
    }
}

/// The verbs Go may invoke.
///
/// ⚠️ **Additive only within a protocol major version** (D16). A desktop that
/// receives a method it does not recognise must answer
/// `.failure(.unsupportedMethod)` — NOT drop the connection. Swift's synthesized
/// enum `Codable` throws on an unknown case, so the dispatcher is responsible
/// for catching that decode failure and converting it into that response; see
/// `RPCErrorCode.unsupportedMethod`.
public enum RPCMethod: Codable, Sendable, Equatable {

    // ── Read ─────────────────────────────────────────────────────────────
    case listProjects
    case listWorktrees(projectID: UUID?)
    case fleetSummary
    case reviewItems
    case monitorSummary(worktreeID: UUID)
    case listPanes(worktreeID: UUID)

    // ── Conversations ────────────────────────────────────────────────────
    /// Every readable agent session, most-recent activity first. `projectID`
    /// scopes it; `nil` means every project.
    case listConversations(projectID: UUID?)
    /// One conversation's messages, oldest → newest — **and subscribes** to its
    /// appends, exactly as `attachTerminal` both backfills and starts the
    /// stream. One call rather than fetch-then-subscribe because the two-call
    /// version has a gap: a message appended between the fetch and the
    /// subscribe belongs to neither, and the thread silently loses a line.
    ///
    /// `limit` is the phone's request, not a promise: the desktop holds a
    /// bounded window per transcript, and says so via `hasOlder` rather than
    /// serving a thread that begins in the middle as though it were complete.
    case conversationMessages(conversationID: UUID, limit: Int)
    /// Stop streaming this conversation (the `detachTerminal` sibling). A
    /// dropped socket unsubscribes everything anyway; this is for leaving the
    /// screen while staying connected.
    case unwatchConversation(conversationID: UUID)

    // ── Slash commands ───────────────────────────────────────────────────
    /// The slash commands actually available in this conversation — the
    /// agent's built-ins plus the user's `~/.claude/commands` and the repo's
    /// own `.claude/commands`, as they exist ON DISK right now.
    ///
    /// Both parameters are load-bearing and neither implies the other. The
    /// **worktree** locates the repo, and project commands live in it, so the
    /// honest answer differs between two worktrees running the same agent. The
    /// **agent** cannot be derived from the worktree, because a worktree may
    /// have run several over its life and may be running two at once; the
    /// phone is typing into one specific conversation and knows exactly which.
    ///
    /// A request rather than something the handshake carries, because it reads
    /// the filesystem and the answer changes while a phone is connected: a
    /// command authored mid-session has to be reachable without reconnecting.
    case listSlashCommands(worktreeID: UUID, agent: ConversationAgentDTO)

    // ── Write: unblock an agent ──────────────────────────────────────────
    /// → `AppState.replyToAgent`
    case replyToAgent(worktreeID: UUID, text: String)
    /// → `AppState.answerAgentPermission`. Note the desktop only claims a
    /// permission contract for Claude Code; other agents focus instead of
    /// pressing an unverified key, and will answer `.unsupportedForAgent`.
    case answerPermission(worktreeID: UUID, allow: Bool)

    /// Presses **ESC** in the worktree's agent pane — the CLI's own interrupt,
    /// which stops the agent mid-turn without killing the session.
    ///
    /// Its own verb rather than a `replyToAgent` carrying `"\u{1b}"`, for two
    /// reasons. Reply flattens and appends a carriage return at the pty
    /// boundary (`AgentInjectionContract.replyPayload`), which would submit the
    /// escape as a line instead of delivering it as a keypress. And an
    /// interrupt is not a message: it must reach the agent whatever state the
    /// desktop believes it is in, so it deliberately skips the latched-prompt
    /// guard that governs answering a notification.
    ///
    /// `.terminalInput` already carries raw bytes, but it is pane-addressed and
    /// requires an attached terminal; the conversation screen has none.
    case interruptAgent(worktreeID: UUID)

    // ── Write: fleet ─────────────────────────────────────────────────────
    case enqueueTask(projectID: UUID, prompt: String,
                     agent: AgentKindDTO, baseBranch: String?)
    case approveAndMerge(worktreeID: UUID)
    case createPullRequest(worktreeID: UUID)
    case requestChanges(worktreeID: UUID, text: String)

    // ── Terminal streaming ───────────────────────────────────────────────
    /// Begin receiving `.terminalData` for this pane. The desktop replies with
    /// `.terminalAttached` carrying a scrollback backfill plus the pane's
    /// CURRENT geometry — `onOutputChunk` is a live tap with no history, so
    /// without the backfill a phone attaching mid-session sees a blank screen
    /// until the agent happens to emit something (D8).
    case attachTerminal(paneID: UUID)
    case detachTerminal(paneID: UUID)
}

public enum RPCResult: Codable, Sendable, Equatable {
    case projects([ProjectDTO])
    case worktrees([WorktreeDTO])
    case fleetSummary(FleetSummaryDTO)
    case reviewItems([ReviewItemDTO])
    case monitorSummary(MonitorSummaryDTO?)
    case conversations([ConversationDTO])
    case conversationMessages(ConversationMessagesDTO)
    case slashCommands([SlashCommandDTO])
    case panes([PaneDTO])
    case terminalAttached(TerminalAttachment)
    /// A mutating verb that succeeded and has nothing to return.
    case ok
    case failure(RPCError)
}

public struct RPCError: Codable, Sendable, Equatable, Error {
    public let code: RPCErrorCode
    /// Human-readable, surfaced verbatim in Go. Desktop-side failures (a git
    /// hook rejection, `gh` stderr) are already surfaced verbatim on the
    /// desktop; do the same here rather than flattening to "something failed".
    public let message: String

    public init(code: RPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RPCErrorCode: String, Codable, Sendable, Equatable {
    case unauthorized
    case notFound
    /// This desktop build does not know the requested method — i.e. Go is
    /// NEWER than the Mac. The actionable path is "update Shiftover".
    case unsupportedMethod
    /// The verb exists but not for this worktree's agent (e.g. a permission
    /// answer for an agent whose TUI contract is uncharacterised).
    case unsupportedForAgent
    /// Precondition failed — e.g. approve-and-merge on a dirty tree.
    case preconditionFailed
    case incompatibleVersion
    case internalError
}

/// Everything Go needs to start rendering a live terminal.
public struct TerminalAttachment: Codable, Sendable, Equatable {
    public let paneID: UUID
    /// **The desktop owns the winsize.** Go renders at these dimensions and
    /// zooms/letterboxes to fit the phone; it must NOT renegotiate, or it
    /// reflows the desktop pane under the user and wrecks any running TUI (D8).
    public let cols: Int
    public let rows: Int
    /// Scrollback prefix to feed before switching to the live stream.
    public let backfill: Data

    public init(paneID: UUID, cols: Int, rows: Int, backfill: Data) {
        self.paneID = paneID
        self.cols = cols
        self.rows = rows
        self.backfill = backfill
    }
}
