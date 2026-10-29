import XCTest
@testable import ShiftoverProtocol

final class BrowserTests: XCTestCase {
    private let pane = UUID()
    private func frame(width: Int = 1024, jpeg: Data = Data([255, 216, 1, 2, 255, 217])) -> BrowserFrame {
        BrowserFrame(paneID: pane, sequence: 42, width: width, height: 768,
                     viewportWidth: 1440, viewportHeight: 1080, url: "http://localhost:3000/",
                     title: "Shared browser", canGoBack: true, canGoForward: false,
                     isLoading: false, jpeg: jpeg)
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
