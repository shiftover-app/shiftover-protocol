import Foundation
import XCTest
@testable import ShiftoverProtocol

final class FileAttachmentTests: XCTestCase {
    func testEveryUploadOperationRequiresControlAndPresence() throws {
        let id = UUID()
        let methods: [RPCMethod] = [
            .beginAttachment(worktreeID: id, name: "photo.png", size: 123),
            .appendAttachment(id: id, offset: 0, data: Data([0, 255, 42])),
            .finishAttachment(id: id, sha256: Data(repeating: 1, count: 32)),
            .cancelAttachment(id: id)
        ]
        for method in methods {
            XCTAssertTrue(method.isWrite)
            let request = RPCRequest(method: method)
            XCTAssertEqual(try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(request)), request)
        }
    }

    func testUploadRepliesAndCapabilityRoundTrip() throws {
        for result: RPCResult in [.attachmentStarted(id: UUID()), .attachmentProgress(offset: 65536),
                                  .attachmentReady(path: "/tmp/a photo.png")] {
            XCTAssertEqual(try JSONDecoder().decode(RPCResult.self, from: JSONEncoder().encode(result)), result)
        }
        XCTAssertEqual(try JSONDecoder().decode(Capability.self, from: JSONEncoder().encode(Capability.fileAttachments)), .fileAttachments)
    }
}
