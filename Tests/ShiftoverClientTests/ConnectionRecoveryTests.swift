import XCTest
@testable import ShiftoverClient

@MainActor
final class ConnectionRecoveryTests: XCTestCase {
    func testRetriesThenReturnsToHealthChecks() async throws {
        let recovered = expectation(description: "recovered")
        var attempts = 0
        var delays: [Int] = []
        let recovery = ConnectionRecovery(healthyInterval: .seconds(60), retryDelay: {
            delays.append($0); return .milliseconds(5)
        }) {
            attempts += 1
            if attempts < 3 { return .retry }
            recovered.fulfill()
            return .healthy
        }
        recovery.start(immediately: true)
        await fulfillment(of: [recovered], timeout: 2)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [0, 1])
        recovery.stop()
    }

    func testManyDisconnectSignalsDoNotOverlapAttempts() async throws {
        let entered = expectation(description: "entered")
        var resume: CheckedContinuation<ConnectionRecovery.Outcome, Never>?
        var attempts = 0
        let recovery = ConnectionRecovery {
            attempts += 1
            return await withCheckedContinuation { resume = $0; entered.fulfill() }
        }
        recovery.start(immediately: true)
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<20 { recovery.checkSoon() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(attempts, 1)
        recovery.stop()
        resume?.resume(returning: .retry)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(recovery.running)
        XCTAssertEqual(attempts, 1)
    }

    func testStopCancelsScheduledRetry() async throws {
        let attempted = expectation(description: "attempted")
        var attempts = 0
        let recovery = ConnectionRecovery(retryDelay: { _ in .milliseconds(100) }) {
            attempts += 1; attempted.fulfill(); return .retry
        }
        recovery.start(immediately: true)
        await fulfillment(of: [attempted], timeout: 2)
        recovery.stop()
        recovery.checkSoon()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(attempts, 1)
    }

    func testRefusalStopsRatherThanRetryingForever() async throws {
        var attempts = 0
        let stopped = expectation(description: "stopped")
        let recovery = ConnectionRecovery(retryDelay: { _ in .milliseconds(5) }) {
            attempts += 1; stopped.fulfill(); return .stop
        }
        recovery.start(immediately: true)
        await fulfillment(of: [stopped], timeout: 2)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(recovery.running)
    }

    func testTransportFailuresCanRetryButIdentityAndPermissionFailuresCannot() {
        for error in [RemoteClient.ClientError.notConnected, .macOffline, .macUnreachable, .transport("timeout")] {
            XCTAssertTrue(RemoteClient.canRetry(error))
        }
        XCTAssertTrue(RemoteClient.canRetry(URLError(.networkConnectionLost)))
        for error in [RemoteClient.ClientError.handshakeFailed("wrong Mac"), .notAuthorized,
                      .refused(.incompatibleVersion, "update"), .unexpectedResult] {
            XCTAssertFalse(RemoteClient.canRetry(error))
        }
        XCTAssertFalse(RemoteClient.canRetry(CancellationError()))
        XCTAssertFalse(RemoteClient.canRetry(URLError(.serverCertificateUntrusted)))
    }
}
