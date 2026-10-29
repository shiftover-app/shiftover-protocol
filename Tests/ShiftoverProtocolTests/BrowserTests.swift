import XCTest
@testable import ShiftoverProtocol

final class BrowserTests: XCTestCase {
    private let pane = UUID()
    private func frame(width: Int = 1024, jpeg: Data = Data([255, 216, 1, 2, 255, 217]),
                       context: String? = nil) -> BrowserFrame {
        BrowserFrame(paneID: pane, sequence: 42, width: width, height: 768,
                     viewportWidth: 1440, viewportHeight: 1080, url: "http://localhost:3000/",
                     title: "Shared browser", canGoBack: true, canGoForward: false,
                     isLoading: false, jpeg: jpeg, interactionContext: context)
    }

    func testBinaryRoundtripAndTruncation() throws {
        let original = frame()
        let encoded = try XCTUnwrap(original.encoded())
        XCTAssertEqual(BrowserFrame.decode(encoded), original)
        XCTAssertEqual(encoded.suffix(original.jpeg.count), original.jpeg)
        for count in [0, 1, 3, 4, encoded.count - 1] {
            XCTAssertNil(BrowserFrame.decode(Data(encoded.prefix(count))))
        }
        XCTAssertNil(BrowserFrame.decode(Data([255, 255, 255, 255, 0, 0, 0, 0])))
        XCTAssertNil(frame(width: 0).encoded())
        XCTAssertNil(frame(width: BrowserFrame.maximumDimension + 1).encoded())
        XCTAssertNil(frame(jpeg: Data(repeating: 0, count: BrowserFrame.maximumJPEGBytes + 1)).encoded())
    }

    func testInteractionContextRoundtripBoundsAndOlderFrame() throws {
        let context = "{\"document\":\"opaque-token\",\"viewport\":[1440,1080]}"
        let original = frame(context: context)
        XCTAssertEqual(BrowserFrame.decode(try XCTUnwrap(original.encoded())), original)
        let boundary = String(repeating: "é", count: BrowserFrame.maximumInteractionContextBytes / 2)
        XCTAssertNotNil(frame(context: boundary).encoded())
        XCTAssertNil(frame(context: boundary + "a").encoded())

        let encoded = try XCTUnwrap(original.encoded())
        let count = encoded.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.dropFirst(4).prefix(count))) as? [String: Any])
        func rebuild(_ metadata: [String: Any]) throws -> Data {
            let json = try JSONSerialization.data(withJSONObject: metadata)
            let size = UInt32(json.count)
            var value = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
            value.append(json)
            value.append(original.jpeg)
            return value
        }
        metadata.removeValue(forKey: "interactionContext")
        XCTAssertEqual(BrowserFrame.decode(try rebuild(metadata)), frame(), "pre-context peers omit the field")
        metadata["interactionContext"] = boundary + "a"
        XCTAssertNil(BrowserFrame.decode(try rebuild(metadata)), "untrusted peers cannot bypass the UTF-8 bound")
    }

    func testInputContextPreservesRequestIdentityAndOlderRequests() throws {
        let request = RPCRequest(method: .browserInput(paneID: pane, input: .tap(x: 0.2, y: 0.3), context: "frame-context"))
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(RPCRequest.self, from: data), request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var method = try XCTUnwrap(object["method"] as? [String: Any])
        var input = try XCTUnwrap(method["browserInput"] as? [String: Any])
        input.removeValue(forKey: "context")
        method["browserInput"] = input
        object["method"] = method
        let oldRequest = try JSONDecoder().decode(RPCRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(oldRequest.id, request.id)
        XCTAssertEqual(oldRequest.method, .browserInput(paneID: pane, input: .tap(x: 0.2, y: 0.3)))
    }

    func testInputBoundsAndURLSchemes() {
        XCTAssertTrue(BrowserInput.tap(x: 0, y: 1).isValid)
        XCTAssertFalse(BrowserInput.tap(x: .nan, y: 0).isValid)
        XCTAssertFalse(BrowserInput.tap(x: 1.1, y: 0).isValid)
        XCTAssertFalse(BrowserInput.scroll(deltaX: .infinity, deltaY: 1).isValid)
        XCTAssertFalse(BrowserInput.scroll(deltaX: 0, deltaY: 10001).isValid)
        XCTAssertFalse(BrowserInput.text(String(repeating: "a", count: 16385)).isValid)
        for url in ["javascript:alert(1)", "file:///etc/passwd", "https:///", "http://user:pass@localhost/"] {
            XCTAssertFalse(BrowserInput.navigate(url: url).isValid, url)
        }
        XCTAssertTrue(BrowserInput.navigate(url: "http://localhost:3000/path").isValid)
    }

    func testRPCClassificationAndRoundtrip() throws {
        let reads: [RPCMethod] = [.attachBrowser(paneID: pane), .detachBrowser(paneID: pane),
                                 .browserFrameAcknowledged(paneID: pane, sequence: 42)]
        let inputs: [BrowserInput] = [.navigate(url: "https://example.com"), .back, .forward, .reload,
                                     .tap(x: 0.2, y: 0.3), .scroll(deltaX: 0, deltaY: 100), .text("Hello 🌎"), .key(.enter)]
        for method in reads + inputs.map({ .browserInput(paneID: pane, input: $0) }) {
            XCTAssertEqual(try JSONDecoder().decode(RPCMethod.self, from: JSONEncoder().encode(method)), method)
            XCTAssertEqual(method.guestScope, .denied)
        }
        for method in reads { XCTAssertFalse(method.isWrite) }
        for input in inputs { XCTAssertTrue(RPCMethod.browserInput(paneID: pane, input: input).isWrite) }
        let event = ServerEvent.browserClosed(paneID: pane, reason: "Pane closed")
        XCTAssertEqual(try JSONDecoder().decode(ServerEvent.self, from: JSONEncoder().encode(event)), event)
    }
}
