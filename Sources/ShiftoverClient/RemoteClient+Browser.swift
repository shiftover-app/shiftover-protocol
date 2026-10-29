import Foundation
import ShiftoverProtocol

@MainActor
public extension RemoteClient {
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

    func sendBrowserInput(paneID: UUID, input: BrowserInput) async throws {
        guard input.isValid else { throw ClientError.transport("Invalid browser input.") }
        try await perform(.browserInput(paneID: paneID, input: input))
    }
}
