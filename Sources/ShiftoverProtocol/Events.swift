import Foundation

// MARK: - Server-push events
//
// Desktop → phone, unsolicited, over `.event` frames. These exist so Go does not
// poll: the desktop already funnels every agent signal through ONE choke point
// (`handleAgentStatusTransition`), which is also where push is triggered, so a
// connected phone can be told directly and a disconnected one gets an APNs
// wake-up carrying no content.
//
// ⚠️ Same additive-only rule as `RPCMethod` (D16): an older Go that cannot
// decode an event must SKIP it, never drop the connection.

public enum ServerEvent: Codable, Sendable, Equatable {
    /// The rendered `AgentStatus` for a worktree changed. `previous` lets Go
    /// distinguish "entered a waiting state" (worth surfacing) from ordinary
    /// churn, matching how the desktop gates its own notifications.
    case agentStatusChanged(worktreeID: UUID,
                            previous: AgentStatusDTO,
                            current: AgentStatusDTO,
                            message: String?)

    /// Worktrees were added/removed/renamed — Go should re-fetch its list.
    /// Deliberately a hint rather than a payload: the full list is cheap to
    /// re-request and this avoids two sources of truth drifting.
    case worktreesChanged

    case fleetSummaryChanged(FleetSummaryDTO)

    /// New messages were appended to a conversation the phone is watching.
    ///
    /// Carries the messages rather than a "go re-fetch" hint — the opposite of
    /// `worktreesChanged`, and deliberately so. This is the one stream where
    /// latency IS the product: watching a reply arrive is the feature, and a
    /// round trip per append would both add delay and re-send a thread already
    /// on screen. Append-only with stable ids, so a client applies these
    /// blindly. Sent only to a device that subscribed by opening the
    /// conversation — an unopened one costs nothing.
    case conversationMessagesAppended(conversationID: UUID,
                                      messages: [AgentMessageDTO])

    /// A conversation's metadata changed — status, model, count, or a new
    /// session appearing. A hint: the list is cheap to re-request.
    case conversationsChanged

    /// The attached pane's pty was resized on the Mac. Go re-letterboxes; it
    /// never initiates a resize itself (D8).
    case terminalResized(paneID: UUID, cols: Int, rows: Int)

    /// The pane went away (closed, tab closed, shell exited). Go should tear
    /// down its emulator rather than showing a frozen last frame.
    case terminalClosed(paneID: UUID)

    /// The desktop is going away deliberately (quit, sleep, bridge disabled).
    /// Lets Go show "Mac disconnected" instead of a generic network error —
    /// and, importantly, not retry-storm a machine that is asleep.
    case hostGoingAway(reason: GoingAwayReason)
}

public enum GoingAwayReason: String, Codable, Sendable, Equatable {
    case quitting
    case sleeping
    case remoteDisabled
    case deviceRevoked
}
