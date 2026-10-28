import XCTest
@testable import ShiftoverProtocol

final class AgentInsightsTests: XCTestCase {
    func testRoundTripAndReadOnlyClassification() throws {
        let method = RPCMethod.agentInsights(worktreeID: UUID())
        XCTAssertFalse(method.isWrite)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        let dto = AgentInsightsDTO(sessions: [.init(id: UUID(), sessionID: "exact", model: "Model", contextUsed: 20, contextLimit: 100, outputTokens: 15)],
            providers: [.init(id: "claude", name: "Claude", state: "ready", windows: [.init(label: "Weekly", percentUsed: 42)])], observedAt: Date(timeIntervalSince1970: 100))
        let result = RPCResult.agentInsights(dto)
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
    }
    func testProviderUsageDoesNotRequireAProject() throws {
        let method = RPCMethod.providerUsage
        XCTAssertFalse(method.isWrite)
        XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        let result = RPCResult.providerUsage([.init(id: "codex", name: "Codex", state: "loading")])
        XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
    }
    func testWindowKindRoundTripsAndIsOptional() throws {
        let window = ProviderUsageWindowDTO(label: "5-hour window", percentUsed: 12, kind: ProviderUsageWindowDTO.sessionKind)
        XCTAssertEqual(try JSONDecoder().decode(ProviderUsageWindowDTO.self, from: JSONEncoder().encode(window)), window)
        XCTAssertTrue(try XCTUnwrap(String(data: JSONEncoder().encode(window), encoding: .utf8)).contains("\"kind\":\"session\""))
        // A Mac that predates `kind` sends only the label, and a window without
        // one leaves no key, which is all an older phone has ever seen.
        let old = try JSONDecoder().decode(ProviderUsageWindowDTO.self, from: Data("{\"label\":\"Weekly\",\"percentUsed\":3}".utf8))
        XCTAssertNil(old.kind)
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8)).contains("kind"))
    }
    func testMissingMetricsRemainUnknown() throws {
        let data = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"sessionID\":\"unknown\"}".utf8)
        let dto = try JSONDecoder().decode(AgentSessionInsightDTO.self, from: data)
        XCTAssertNil(dto.contextUsed); XCTAssertNil(dto.estimatedCostUSD); XCTAssertNil(dto.startedAt)
    }
}
