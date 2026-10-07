import Foundation

/// Text projection of a shell. The shared terminal's prompt and geometry are
/// unchanged. History is bounded and starts when the command view is first opened.
public struct ShellSnapshotDTO: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case ready, running, editing, unavailable }
    public var state: State
    public var promptID: UUID?
    public var commands: [ShellCommandDTO]
    public var message: String?
    public init(state: State, promptID: UUID? = nil, commands: [ShellCommandDTO] = [], message: String? = nil) {
        self.state = state; self.promptID = promptID; self.commands = commands; self.message = message
    }
}

public struct ShellCommandDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var command: String
    public var output: String
    public var isRunning: Bool
    public var isTruncated: Bool
    public init(id: UUID = UUID(), command: String, output: String = "", isRunning: Bool = false, isTruncated: Bool = false) {
        self.id = id; self.command = command; self.output = output; self.isRunning = isRunning; self.isTruncated = isTruncated
    }
}
