// MARK: - Live Activity (the Mac's agents on the phone's lock screen and Dynamic Island)
//
// While agents run, the phone shows a Live Activity: which agents are working,
// which wait on the user, which finished, and a usage limit if one was hit. The
// Mac sends each change through the relay as an ActivityKit push.
//
// ActivityKit hands a push's `content-state` straight to the widget extension,
// with no service extension in between, so whatever it holds is visible to the
// relay and to Apple. So, as for notifications, the Mac seals the content to
// the phone's key (HPKE auth mode, its own `info` label) and the content state
// is only the box; the widget extension opens it when it draws. What leaks is
// what a notification leaks: that an update happened, when, and its rough size.

import CryptoKit
import Foundation

/// What a Live Activity shows. Sealed end to end, like `PushContent`.
public struct AgentsActivityContent: Codable, Sendable, Hashable {

    public struct Agent: Codable, Sendable, Hashable {
        public let worktreeID: UUID
        /// The pane a tap opens, when the Mac could tell.
        public let paneID: UUID?
        public let project: String
        public let branch: String
        /// The agent CLI (an `AgentKindDTO` raw value), when the Mac could tell
        /// which one runs there. A string, so a phone that does not know a newer
        /// agent still opens the content and draws a generic mark for it.
        public let agent: String?
        public let status: AgentStatusDTO
        /// When the worktree entered `status`: the turn's start while working,
        /// the question while waiting, the turn's end once finished.
        public let since: Date

        public init(worktreeID: UUID, paneID: UUID? = nil, project: String, branch: String,
                    agent: String?, status: AgentStatusDTO, since: Date) {
            self.worktreeID = worktreeID
            self.paneID = paneID
            self.project = AgentsActivityContent.trimmed(project)
            self.branch = AgentsActivityContent.trimmed(branch)
            self.agent = agent
            self.status = status
            self.since = since
        }

        /// Waiting on the user first, then errors, work, and finished turns.
        var urgency: Int {
            switch status {
            case .input, .permission: return 0
            case .error: return 1
            case .working: return 2
            case .done: return 3
            case .idle, .present: return 4
            }
        }
    }

    /// A provider's session window that ran out.
    public struct Limit: Codable, Sendable, Hashable {
        /// The usage provider, e.g. "claude".
        public let providerID: String
        public let providerName: String
        public let resetsAt: Date
        /// Agents set to resume when the window resets.
        public let resuming: Int
        public let weeklyPercent: Double?
        public let weeklyResetsAt: Date?

        public init(providerID: String, providerName: String, resetsAt: Date, resuming: Int,
                    weeklyPercent: Double? = nil, weeklyResetsAt: Date? = nil) {
            self.providerID = providerID
            self.providerName = providerName
            self.resetsAt = resetsAt
            self.resuming = resuming
            self.weeklyPercent = weeklyPercent
            self.weeklyResetsAt = weeklyResetsAt
        }
    }

    /// The Mac's name, as the phone lists it.
    public let macName: String
    /// The most urgent agents, in `ordered` order, at most `maxAgents`.
    public let agents: [Agent]
    /// Every agent there was to list, including those past `maxAgents`.
    public let agentCount: Int
    public let limit: Limit?
    public let sentAt: Date

    /// How many agents a Live Activity lists. Its lock-screen view has room
    /// for three rows; the fourth only feeds the count.
    public static let maxAgents = 4
    /// Names are cut to this many characters: a Live Activity push caps at
    /// 4 KB, and a row shows far fewer.
    static let maxNameLength = 60

    /// Orders `agents` and keeps the first `maxAgents`. Idle and merely
    /// present worktrees are not listed at all.
    public init(macName: String, agents: [Agent], limit: Limit?, sentAt: Date = Date()) {
        let listed = Self.ordered(agents.filter { $0.urgency < 4 })
        self.macName = Self.trimmed(macName)
        self.agents = Array(listed.prefix(Self.maxAgents))
        self.agentCount = listed.count
        self.limit = limit
        self.sentAt = sentAt
    }

    /// Whether there is anything to keep the Live Activity open for: an agent
    /// working or waiting, or a limit counting down. Finished turns alone are
    /// shown until the activity is dismissed, not kept alive.
    public var isActive: Bool {
        if limit != nil { return true }
        return agents.contains { $0.urgency == 0 || $0.status == .working }
    }

    /// Whether the two would draw the same: everything but `sentAt`.
    public func showsSame(as other: AgentsActivityContent) -> Bool {
        macName == other.macName && agents == other.agents
            && agentCount == other.agentCount && limit == other.limit
    }

    /// Most urgent first. Among agents waiting or working, the longest waiting
    /// or running first; among finished ones, the newest first.
    public static func ordered(_ agents: [Agent]) -> [Agent] {
        agents.sorted { a, b in
            if a.urgency != b.urgency { return a.urgency < b.urgency }
            if a.since != b.since { return a.urgency == 3 ? a.since > b.since : a.since < b.since }
            return a.worktreeID.uuidString < b.worktreeID.uuidString
        }
    }

    static func trimmed(_ name: String) -> String {
        name.count > maxNameLength ? String(name.prefix(maxNameLength - 1)) + "…" : name
    }
}

public enum ActivitySealing {

    static let info = Data("shiftover-activity/v1".utf8)

    /// Seals `content` to the phone, authenticated as the Mac.
    public static func seal(_ content: AgentsActivityContent, toPhoneKey phoneKey: Data,
                            from mac: RemoteIdentityKey) throws -> SealedPush {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey) else {
            throw PushSealing.SealError.invalidKey
        }
        guard let plaintext = try? JSONEncoder().encode(content) else {
            throw PushSealing.SealError.sealFailed
        }
        return try PushSealing.sealData(plaintext, info: info, to: recipient, from: mac)
    }

    /// Opens a Live Activity's content on the phone. `nil` if no paired Mac
    /// sealed it, it was tampered with, or it claims to come from the future.
    ///
    /// Unlike a push there is no maximum age: the content stands until the Mac
    /// sends the next, which may be hours later while an agent works. iOS
    /// marks the activity stale on its own (`stale-date`), and draws only the
    /// newest update it was given.
    public static func open(_ sealed: SealedPush, with phone: RemoteIdentityKey,
                            fromAnyOf macKeys: [Data], now: Date = Date())
    -> (content: AgentsActivityContent, macKey: Data)? {
        guard let (plaintext, macKey) = PushSealing.openData(sealed, info: info, with: phone,
                                                             fromAnyOf: macKeys),
              let content = try? JSONDecoder().decode(AgentsActivityContent.self, from: plaintext),
              content.sentAt.timeIntervalSince(now) <= 60 else { return nil }
        return (content, macKey)
    }

    /// Names a Mac in a Live Activity's attributes without naming it to the
    /// relay: the first 8 bytes of a hash of its public key, in hex. The phone
    /// matches it against its paired Macs to know whose relay an activity's
    /// push token goes to.
    public static func macTag(_ macKey: Data) -> String {
        SHA256.hash(data: Data("shiftover-activity-mac/v1".utf8) + macKey)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
