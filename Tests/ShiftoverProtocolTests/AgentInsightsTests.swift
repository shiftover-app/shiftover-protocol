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
    func testMissingMetricsRemainUnknown() throws {
        let data = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"sessionID\":\"unknown\"}".utf8)
        let dto = try JSONDecoder().decode(AgentSessionInsightDTO.self, from: data)
        XCTAssertNil(dto.contextUsed); XCTAssertNil(dto.estimatedCostUSD); XCTAssertNil(dto.startedAt)
    }
}
