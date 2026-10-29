import Foundation
import ShiftoverProtocol

@MainActor
public extension RemoteClient {
    func openBrowser(worktreeID: UUID) async throws -> UUID {
        guard case .connected(_, let capabilities) = state,
              capabilities.contains(.browserCreation) else {
            throw ClientError.transport("Update Shiftover on your Mac to open Browser panes remotely.")
        }
        switch try await call(.openBrowser(worktreeID: worktreeID)) {
        case .browserOpened(let paneID): return paneID
        case .failure(let error): throw ClientError.transport(error.message)
        default: throw ClientError.unexpectedResult
        }
    }

    func attachBrowser(paneID: UUID) async throws {
        guard case .connected(_, let capabilities) = state,
              capabilities.contains(.browserStream) else {
            throw ClientError.transport("Update Shiftover on your Mac to stream Browser panes.")
        }
        try await perform(.attachBrowser(paneID: paneID))
    }

    func detachBrowser(paneID: UUID) async throws {
        try await perform(.detachBrowser(paneID: paneID))
    }

    func acknowledgeBrowserFrame(paneID: UUID, sequence: UInt64) async throws {
        try await perform(.browserFrameAcknowledged(paneID: paneID, sequence: sequence))
    }

    func sendBrowserInput(paneID: UUID, input: BrowserInput, context: String? = nil) async throws {
        guard input.isValid,
              (context?.utf8.count ?? 0) <= BrowserFrame.maximumInteractionContextBytes else {
            throw ClientError.transport("Invalid browser input.")
        }
        try await perform(.browserInput(paneID: paneID, input: input, context: context))
    }
}
