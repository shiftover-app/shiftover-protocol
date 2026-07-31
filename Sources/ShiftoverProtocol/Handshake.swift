import Foundation

// MARK: - Handshake
//
// Exchanged before any other frame, over an already-authenticated transport.
// This does NOT carry credentials: pairing is Mac-authoritative and happens
// out of band (PLAN_45 D14 — the QR carries service name + cert SPKI hash + a
// one-time secret; the Mac mints the device token). By the time a Hello is
// sent, both ends already trust each other; the handshake only establishes
// *what they can say to each other*.
//
// That separation is what lets the relay stay a dumb ciphertext pipe — it
// authenticates for BILLING, never for TRUST (D5/D13).

public struct Hello: Codable, Sendable, Equatable {
    /// Wire-protocol version (`ProtocolVersion.current`). The only field whose
    /// meaning is load-bearing rather than diagnostic.
    public let protocolVersion: Int
    /// Marketing version of the sending build, e.g. "0.4.2". Diagnostics only —
    /// never branch on this, branch on `protocolVersion`.
    public let appVersion: String
    /// Stable per-device identity, minted by the Mac at pairing.
    public let deviceID: UUID
    /// Human-readable, for the desktop's paired-device list. e.g. "Marko's iPhone"
    public let deviceName: String

    public init(protocolVersion: Int = ProtocolVersion.current,
                appVersion: String,
                deviceID: UUID,
                deviceName: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public struct HelloAck: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let appVersion: String
    /// The Mac's name, shown in Go's host picker. e.g. "Markos-MacBook-Pro"
    public let hostName: String
    /// What this desktop build will actually honour. Lets Go hide affordances
    /// it knows the other end cannot serve, rather than surfacing a failure
    /// after the user taps.
    public let capabilities: Set<Capability>

    public init(protocolVersion: Int = ProtocolVersion.current,
                appVersion: String,
                hostName: String,
                capabilities: Set<Capability>) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.hostName = hostName
        self.capabilities = capabilities
    }
}

/// Feature flags negotiated at connect time.
///
/// Raw-value strings (not ints) so an unknown capability from a newer peer
/// decodes into `.unknown` instead of failing the whole `HelloAck` — the same
/// additively-ignorable discipline as `FrameType` (D16).
public enum Capability: String, Codable, Sendable, Hashable {
    /// Read-only surfaces: fleet, status, monitor, review.
    case read
    /// Mutating verbs: reply, permission, merge, PR, enqueue.
    case write
    /// Live pty streaming (`.terminalData` / `.terminalInput`).
    case terminalStream
    /// Desktop can request a push through Cloud on this device's behalf.
    case push
    /// Any capability this build does not recognise.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Capability(rawValue: raw) ?? .unknown
    }
}
