import Foundation

/// A live request, independent of transcript history. IDs belong to a provider
/// connection and session; clients must never replay answers against a new ID.
public struct AgentQuestionDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var options: [String]
    public var descriptions: [String]
    public var multiple: Bool
    public var allowsText: Bool
    public var isSecret: Bool
    public init(id: String, title: String, options: [String] = [], descriptions: [String] = [],
                multiple: Bool = false, allowsText: Bool = true, isSecret: Bool = false) {
        self.id = id; self.title = title; self.options = options; self.descriptions = descriptions
        self.multiple = multiple; self.allowsText = allowsText; self.isSecret = isSecret
    }
}

public struct AgentQuestionRequestDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var questions: [AgentQuestionDTO]
    public var isBlocking: Bool
    public init(id: String, questions: [AgentQuestionDTO], isBlocking: Bool) {
        self.id = id; self.questions = questions; self.isBlocking = isBlocking
    }
}

/// Verified live terminal prompt for a provider without a structured answer
/// connection. Only the explicitly listed controls can be sent to this screen.
public struct AgentQuestionTerminalDTO: Codable, Sendable, Equatable {
    public var revision: String
    public var text: String
    public var controls: [AgentQuestionKey]
    public init(revision: String, text: String, controls: [AgentQuestionKey]) {
        self.revision = revision; self.text = text; self.controls = controls
    }
}

public enum AgentQuestionKey: String, Codable, Sendable, CaseIterable {
    case reveal, up, down, left, right, tab, space, enter, escape
}

public struct AgentQuestionsDTO: Codable, Sendable, Equatable {
    public var requests: [AgentQuestionRequestDTO]
    public var terminal: AgentQuestionTerminalDTO?
    public init(requests: [AgentQuestionRequestDTO] = [], terminal: AgentQuestionTerminalDTO? = nil) {
        self.requests = requests; self.terminal = terminal
    }
    public var isEmpty: Bool { requests.isEmpty && terminal == nil }
}

public enum AgentQuestionAnswer: Codable, Sendable, Equatable {
    case answers(requestID: String, values: [String: [String]])
    case key(revision: String, key: AgentQuestionKey)
    /// Paste text without submitting. Enter is a separate explicit action.
    case text(revision: String, text: String)
}
