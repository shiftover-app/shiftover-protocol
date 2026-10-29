import Foundation

public enum BrowserKey: String, Codable, Sendable, Equatable, CaseIterable {
    case enter, tab, backspace, escape
}

/// Coordinates refer to the displayed frame, not the phone's screen. Taps use
/// normalized viewport coordinates; scrolling uses CSS-pixel deltas.
public enum BrowserInput: Codable, Sendable, Equatable {
    case navigate(url: String)
    case back, forward, reload
    case tap(x: Double, y: Double)
    case scroll(deltaX: Double, deltaY: Double)
    case text(String)
    case key(BrowserKey)

    /// Both peers validate before acting. Remote write/presence checks are
    /// still required; valid input is not authorization.
    public var isValid: Bool {
        switch self {
        case .navigate(let value):
            guard value.utf8.count <= 8192, let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return false }
            return true
        case .tap(let x, let y): return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
        case .scroll(let x, let y): return x.isFinite && y.isFinite && abs(x) <= 10000 && abs(y) <= 10000
        case .text(let text): return text.utf8.count <= 16384
        case .back, .forward, .reload, .key: return true
        }
    }
}

/// One full JPEG snapshot and the state captured with it. Encoded as
/// [4-byte big-endian metadata length][JSON metadata][raw JPEG], then sealed
/// by RemoteChannel like every other bulk frame. Never base64 on the wire.
/// A sender must wait for this sequence's acknowledgement before capturing
/// another frame for that subscriber. Sequence numbers must not be reused on
/// reattach within a connection (a delayed ack must not release a new frame).
public struct BrowserFrame: Sendable, Equatable {
    public static let maximumJPEGBytes = 512 * 1024
    public static let maximumMetadataBytes = 32 * 1024
    public static let maximumDimension = 2048
    public static let maximumInteractionContextBytes = 4096
    public let paneID: UUID
    public let sequence: UInt64
    public let width: Int
    public let height: Int
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let url: String
    public let title: String
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let isLoading: Bool
    public let loadError: String?
    /// Opaque host-owned document/viewport identity, echoed unchanged with input.
    /// Missing on older hosts; receivers must not infer freshness from sequence alone.
    public let interactionContext: String?
    public let jpeg: Data

    public init(paneID: UUID, sequence: UInt64, width: Int, height: Int,
                viewportWidth: Double, viewportHeight: Double, url: String,
                title: String, canGoBack: Bool, canGoForward: Bool,
                isLoading: Bool, jpeg: Data, loadError: String? = nil,
                interactionContext: String? = nil) {
        self.paneID = paneID; self.sequence = sequence
        self.width = width; self.height = height
        self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.url = url; self.title = title
        self.canGoBack = canGoBack; self.canGoForward = canGoForward
        self.isLoading = isLoading; self.jpeg = jpeg; self.loadError = loadError
        self.interactionContext = interactionContext
    }

    private struct Metadata: Codable {
        let paneID: UUID
        let sequence: UInt64
        let width: Int
        let height: Int
        let viewportWidth: Double
        let viewportHeight: Double
        let url: String
        let title: String
        let canGoBack: Bool
        let canGoForward: Bool
        let isLoading: Bool
        let loadError: String?
        let interactionContext: String?
    }

    public var isValid: Bool {
        (1...Self.maximumDimension).contains(width) && (1...Self.maximumDimension).contains(height)
            && viewportWidth.isFinite && viewportHeight.isFinite
            && viewportWidth > 0 && viewportWidth <= 16384
            && viewportHeight > 0 && viewportHeight <= 16384
            && (loadError?.utf8.count ?? 0) <= 8192
            && (interactionContext?.utf8.count ?? 0) <= Self.maximumInteractionContextBytes
            && url.utf8.count <= 8192 && title.utf8.count <= 8192
            && jpeg.count >= 4 && jpeg.count <= Self.maximumJPEGBytes
            && jpeg.starts(with: [0xff, 0xd8]) && jpeg.suffix(2) == Data([0xff, 0xd9])
    }

    public func encoded() -> Data? {
        guard isValid else { return nil }
        let metadata = Metadata(paneID: paneID, sequence: sequence, width: width, height: height,
                                viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                                url: url, title: title, canGoBack: canGoBack,
                                canGoForward: canGoForward, isLoading: isLoading, loadError: loadError,
                                interactionContext: interactionContext)
        guard let json = try? JSONEncoder().encode(metadata), json.count <= Self.maximumMetadataBytes else { return nil }
        let count = UInt32(json.count)
        var result = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(json); result.append(jpeg)
        return result
    }

    public static func decode(_ data: Data) -> BrowserFrame? {
        guard data.count >= 8, data.count <= 4 + maximumMetadataBytes + maximumJPEGBytes else { return nil }
        let count = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumMetadataBytes, count <= data.count - 8,
              let meta = try? JSONDecoder().decode(Metadata.self, from: data.dropFirst(4).prefix(count)) else { return nil }
        let frame = BrowserFrame(paneID: meta.paneID, sequence: meta.sequence, width: meta.width, height: meta.height,
                                 viewportWidth: meta.viewportWidth, viewportHeight: meta.viewportHeight,
                                 url: meta.url, title: meta.title, canGoBack: meta.canGoBack,
                                 canGoForward: meta.canGoForward, isLoading: meta.isLoading,
                                 jpeg: Data(data.dropFirst(4 + count)), loadError: meta.loadError,
                                 interactionContext: meta.interactionContext)
        return frame.isValid ? frame : nil
    }
}
