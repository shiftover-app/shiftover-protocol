import XCTest
@testable import ShiftoverProtocol

final class AgentQuestionTests: XCTestCase {
    func testAnswersAreWriteGatedAndRoundTrip() throws {
        let pane = UUID()
        let answers: [AgentQuestionAnswer] = [
            .answers(requestID: "q", values: ["one": ["A", "B"], "two": ["Custom answer"]]),
            .key(revision: "screen", key: .enter), .text(revision: "screen", text: "hello")]
        for answer in answers {
            let method = RPCMethod.answerAgentQuestion(paneID: pane, answer: answer, requestID: UUID())
            XCTAssertTrue(method.isWrite)
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
        }
        XCTAssertFalse(RPCMethod.agentQuestions(paneID: pane).isWrite)
    }
    func testSnapshotKeepsMultipleRequestsAndFreeTextRules() throws {
        let snapshot = AgentQuestionsDTO(requests: [
            .init(id: "blocking", questions: [.init(id: "one", title: "Pick", options: ["A", "B"], multiple: true, allowsText: false)], isBlocking: true),
            .init(id: "async", questions: [.init(id: "two", title: "Why?")], isBlocking: false)],
            terminal: .init(revision: "screen", text: "Actual prompt", controls: [.up, .down, .enter]))
        XCTAssertEqual(try JSONDecoder().decode(AgentQuestionsDTO.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(AgentQuestionsDTO().isEmpty)
    }
    func testHeaderIsOptionalOnTheWire() throws {
        let labelled = AgentQuestionDTO(id: "one", title: "How should purchases work?", options: ["A"], header: "Purchases")
        XCTAssertEqual(try JSONDecoder().decode(AgentQuestionDTO.self, from: JSONEncoder().encode(labelled)), labelled)
        // A host that predates the field sends none.
        let old = #"{"id":"one","title":"Pick","options":["A"],"descriptions":[""],"multiple":false,"allowsText":true,"isSecret":false}"#
        let decoded = try JSONDecoder().decode(AgentQuestionDTO.self, from: Data(old.utf8))
        XCTAssertNil(decoded.header)
        XCTAssertEqual(decoded.title, "Pick")
    }
}
