import Foundation

/// Read-only, worktree-scoped session data. Account limits are deliberately separate.
public struct AgentInsightsDTO: Codable, Sendable, Equatable {
    public var sessions: [AgentSessionInsightDTO]
    public var providers: [ProviderUsageDTO]
    public var observedAt: Date
    public init(sessions: [AgentSessionInsightDTO], providers: [ProviderUsageDTO], observedAt: Date) {
        self.sessions = sessions; self.providers = providers; self.observedAt = observedAt
    }
}

public struct AgentSessionInsightDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID // pane identity
    public var sessionID: String?
    public var model: String?
    public var activity: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var contextUsed: Int?
    public var contextLimit: Int?
    public var outputTokens: Int?
    public var estimatedCostUSD: Double?
    public var promptCount: Int?
    public var unavailableReason: String?
    public init(id: UUID, sessionID: String?, model: String? = nil, activity: String? = nil,
                startedAt: Date? = nil, lastActivityAt: Date? = nil, contextUsed: Int? = nil,
                contextLimit: Int? = nil, outputTokens: Int? = nil, estimatedCostUSD: Double? = nil,
                promptCount: Int? = nil, unavailableReason: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.model = model; self.activity = activity
        self.startedAt = startedAt; self.lastActivityAt = lastActivityAt
        self.contextUsed = contextUsed; self.contextLimit = contextLimit; self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD; self.promptCount = promptCount
        self.unavailableReason = unavailableReason
    }
}

public struct ProviderUsageDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var plan: String?
    /// ready, loading, unavailable, signIn, error. Open vocabulary for older clients.
    public var state: String
    public var updatedAt: Date?
    public var windows: [ProviderUsageWindowDTO]
    public init(id: String, name: String, plan: String? = nil, state: String, updatedAt: Date? = nil, windows: [ProviderUsageWindowDTO] = []) {
        self.id = id; self.name = name; self.plan = plan; self.state = state
        self.updatedAt = updatedAt; self.windows = windows
    }
}

public struct ProviderUsageWindowDTO: Codable, Sendable, Equatable {
    public var label: String
    public var percentUsed: Double
    public var resetsAt: Date?
    public var detail: String?
    public init(label: String, percentUsed: Double, resetsAt: Date? = nil, detail: String? = nil) {
        self.label = label; self.percentUsed = percentUsed; self.resetsAt = resetsAt; self.detail = detail
    }
}
