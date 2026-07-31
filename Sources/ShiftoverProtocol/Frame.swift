import Foundation

// MARK: - Wire framing
//
// One WebSocket message == one frame. There is NO length prefix — the message
// boundary IS the frame boundary. This mirrors the framing Shiftover already
// consumes in `Container/BaguetteStreamClient.swift` ("[1-byte tag][payload],
// no length prefix, the WS message IS the frame"), so the desktop already has a
// working precedent for reading exactly this shape.
//
// Why a byte tag rather than "everything is JSON": terminal output is the
// highest-volume traffic on this channel by an order of magnitude, and
// base64-in-JSON would inflate it ~33% — on a metered cellular link, for the
// one payload type that is already the bandwidth concern (PLAN_45 D8). The tag
// lets bulk frames stay raw bytes while control frames stay comfortable JSON.

public enum FrameType: UInt8, Sendable, CaseIterable {
    // ── Session ──────────────────────────────────────────────────────────
    case hello        = 0x01
    case helloAck     = 0x02

    // ── Control (JSON payloads) ──────────────────────────────────────────
    case request      = 0x10
    case response     = 0x11
    case event        = 0x12

    // ── Bulk (raw payloads, pane-addressed) ──────────────────────────────
    /// Desktop → phone: pty output. `[16B paneID][raw bytes]`
    case terminalData  = 0x20
    /// Phone → desktop: keystrokes. `[16B paneID][raw bytes]`
    case terminalInput = 0x21
}

public struct Frame: Sendable, Equatable {
    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        var out = Data([type.rawValue])
        out.append(payload)
        return out
    }

    /// Decodes one frame off the wire.
    ///
    /// Returns `nil` for an empty message OR an unrecognised tag. **The caller
    /// must SKIP a `nil`, not close the connection** — D16 requires new frame
    /// types to be additively ignorable so a newer peer can introduce one
    /// without breaking an older build. That is the entire reason this returns
    /// an Optional instead of throwing.
    public static func decode(_ data: Data) -> Frame? {
        guard let tag = data.first, let type = FrameType(rawValue: tag) else {
            return nil
        }
        return Frame(type: type, payload: Data(data.dropFirst()))
    }
}

// MARK: - Pane-addressed bulk payload

/// The payload shape of `.terminalData` / `.terminalInput`.
///
/// The pane id rides as 16 raw bytes rather than a UUID string (36 bytes of
/// JSON) because it prefixes EVERY output chunk — the one place in this
/// protocol where 20 bytes per message is worth caring about.
public struct TerminalPayload: Sendable, Equatable {
    public let paneID: UUID
    public let bytes: Data

    public init(paneID: UUID, bytes: Data) {
        self.paneID = paneID
        self.bytes = bytes
    }

    public func encoded() -> Data {
        var out = paneID.protocolBytes
        out.append(bytes)
        return out
    }

    public static func decode(_ data: Data) -> TerminalPayload? {
        guard data.count >= 16,
              let id = UUID(protocolBytes: Data(data.prefix(16)))
        else { return nil }
        return TerminalPayload(paneID: id, bytes: Data(data.dropFirst(16)))
    }
}

extension UUID {
    /// The uuid's 16 raw bytes, in Apple's layout order.
    public var protocolBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    /// Rebuilds a UUID from exactly 16 bytes; `nil` for any other length.
    public init?(protocolBytes data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (b[0],  b[1],  b[2],  b[3],
                         b[4],  b[5],  b[6],  b[7],
                         b[8],  b[9],  b[10], b[11],
                         b[12], b[13], b[14], b[15]))
    }
}
