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
    case workspace
    case createTerminalTab(worktreeID: UUID, requestID: UUID)
    case gitMutate(worktreeID: UUID, action: WorkspaceGitAction, expectedRevision: String, requestID: UUID)
    /// Empty path lists the worktree root. Paths are worktree-relative.
    case browseDirectory(worktreeID: UUID, path: String)
    case readWorkspaceFile(worktreeID: UUID, path: String)
    case gitBranches(worktreeID: UUID)
    /// Compares HEAD's changes since the merge base with an exact branch ref.
    case gitCompare(worktreeID: UUID, baseRef: String)
    case gitCommitDetails(worktreeID: UUID, hash: String)
    /// Immutable commit IDs keep file previews stable while branches move.
    /// A nil base is reserved for a root commit.
    case gitRevisionDiff(worktreeID: UUID, baseHash: String?, headHash: String, path: String)
    case gitSnapshot(worktreeID: UUID)
    case gitFileDiff(worktreeID: UUID, path: String, scope: GitDiffScope)
    /// Reads/updates ONLY the authenticated phone's notification delivery.
    /// RSSI is a hint, never an authorization credential. nil clears stale proximity.
    /// A sample ID identifies an actual radio observation. Repeated polls must
    /// not refresh an old observation or count it toward a sustained transition.
    /// Optional for compatibility with the first presence-capable phone build.
    case notificationPresence(mode: PhoneNotificationMode?, rssi: Int?, sampleID: UUID? = nil)
    case createAgentTab(worktreeID: UUID, agent: AgentKindDTO, prompt: String, requestID: UUID)
    case agentPaneAction(paneID: UUID, sessionID: String?, action: AgentPaneAction)
    case renameAgentTab(tabID: UUID, title: String)
    case listProjects
    case listWorktrees(projectID: UUID?)
    case fleetSummary
    case reviewItems
    case monitorSummary(worktreeID: UUID)
    case reviewDetails(worktreeID: UUID)
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
    /// Worktree-relative file suggestions. The Mac bounds and ranks results;
    /// callers supply an existing worktree ID, never an arbitrary directory.
    case listWorktreeFiles(worktreeID: UUID, query: String)

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

    /// Reconciles the worktree's agent input box to `text` — and, when
    /// `submit` is set, presses Return.
    ///
    /// This is the phone's composer and the Mac's input box being ONE box
    /// rather than two that happen to hold similar strings. It is sent as the
    /// user types, so the Mac shows the message forming, and the same verb
    /// submits it.
    ///
    /// **Full text, not keystrokes**, which is the whole reason this is
    /// tractable. The Mac can read what its box currently contains, so it
    /// computes the difference itself and sends the backspaces and characters
    /// that close it. Three things follow that a keystroke stream does not get:
    /// a dropped or reordered message self-heals on the next one rather than
    /// corrupting the line forever; the phone may coalesce a fast burst of
    /// typing into a single call without the Mac being able to tell; and the
    /// phone needs to know nothing about pty conventions (DEL, bracketed paste)
    /// — that vocabulary stays on the side that owns the terminal.
    ///
    /// `seq` is a per-conversation counter the Mac echoes back in
    /// `agentInputChanged` as `appliedSeq`. It exists for exactly one decision:
    /// the phone adopts the Mac's box only once the ack has caught up with what
    /// it has sent. Before that the box is a stale render of a keystroke still
    /// in flight, and adopting it would delete the characters being typed.
    ///
    /// `submit` is part of this verb rather than its own so that reconcile and
    /// Return are ONE main-actor turn on the Mac. Split in two they can
    /// interleave with a live keystroke, and the failure is silent: the message
    /// is sent a character short.
    case setAgentInput(worktreeID: UUID, text: String, seq: UInt64, submit: Bool)

    // ── Write: fleet ─────────────────────────────────────────────────────
    case enqueueTask(projectID: UUID, prompt: String,
                     agent: AgentKindDTO, baseBranch: String?)
    /// Starts only this task immediately, leaving the existing queue paused.
    case kickoffTask(projectID: UUID, prompt: String, agent: AgentKindDTO, baseBranch: String?)
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
    /// One plain-text screen without subscribing to raw terminal output.
    /// Returns `.ok` when unchanged since the previous snapshot on this session.
    case terminalSnapshot(paneID: UUID)
    /// Structured, prompt-free command/output history for a known shell pane.
    case shellSnapshot(paneID: UUID)
    /// Submit only at the exact empty prompt that the phone last observed.
    /// A prompt ID is consumed once, so retries never execute a command twice.
    case submitShellCommand(paneID: UUID, promptID: UUID, command: String)
}

extension RPCMethod {
    /// Whether this verb changes anything on the Mac.
    ///
    /// Both ends consult it: the Mac refuses these from a device without the
    /// write grant (D9), and the phone asks for Face ID before sending one, so a
    /// phone left unlocked on a table is not a remote shell for whoever picks
    /// it up. One classification, so the two can never disagree about what
    /// counts as a write. Exhaustive by construction — a new verb does not
    /// compile until it is classified.
    public var isWrite: Bool {
        switch self {
        case .gitBranches, .gitCompare, .gitCommitDetails, .gitRevisionDiff, .browseDirectory, .readWorkspaceFile, .gitSnapshot, .gitFileDiff, .notificationPresence, .workspace, .listProjects, .listWorktrees, .fleetSummary, .reviewItems,
             .shellSnapshot, .monitorSummary, .reviewDetails, .listPanes, .attachTerminal, .detachTerminal, .terminalSnapshot,
             // Watching an agent changes what the Mac SENDS, never what it
             // does — which is the point of a read-only device.
             .listConversations, .conversationMessages, .unwatchConversation,
             .listSlashCommands, .listWorktreeFiles:
            return false
        case .submitShellCommand, .createTerminalTab, .gitMutate, .createAgentTab, .agentPaneAction, .renameAgentTab, .replyToAgent, .answerPermission, .enqueueTask, .kickoffTask, .approveAndMerge,
             .createPullRequest, .requestChanges,
             // Stopping an agent mid-turn is one of the more consequential writes.
             .interruptAgent,
             // Characters typed into an agent's input box are really in the
             // Mac's terminal, even before Return.
             .setAgentInput:
            return true
        }
    }
}

public enum RPCResult: Codable, Sendable, Equatable {
    case gitBranches(GitBranchesDTO)
    case gitComparison(GitComparisonDTO)
    case gitCommitDetails(GitCommitDetailsDTO)
    case shellSnapshot(ShellSnapshotDTO)
    case notificationPresence(NotificationPresenceDTO)
    case workspace(WorkspaceDTO)
    case terminalTabCreated(tabID: UUID, paneID: UUID)
    case gitMutationCompleted(message: String)
    case directory(WorkspaceDirectory)
    case workspaceFile(WorkspaceFileContent)
    case gitSnapshot(GitSnapshotDTO)
    case gitFileDiff(GitFileDiffDTO)
    case agentTabCreated(tabID: UUID, paneID: UUID)
    case projects([ProjectDTO])
    case worktrees([WorktreeDTO])
    case fleetSummary(FleetSummaryDTO)
    case reviewItems([ReviewItemDTO])
    case monitorSummary(MonitorSummaryDTO?)
    case reviewDetails(diff: String, commits: String, truncated: Bool)
    case conversations([ConversationDTO])
    case conversationMessages(ConversationMessagesDTO)
    case slashCommands([SlashCommandDTO])
    case worktreeFiles([String])
    case panes([PaneDTO])
    case terminalAttached(TerminalAttachment)
    case taskStarted(worktreeID: UUID)
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
