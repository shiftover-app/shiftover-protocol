import Foundation

// MARK: - Handshake
//
// The first two frames of every connection, LAN or relay. Each carries one
// Noise IK handshake message (see `Noise.swift`), and each Noise message
// carries a sealed payload:
//
//     phone → Mac   .hello     { protocolVersion, handshake: e, es, s, ss, [HelloIdentity] }
//     Mac → phone   .helloAck  { protocolVersion, handshake: e, ee, se, [HelloAckPayload] }
//
// **Only `protocolVersion` travels in the clear**, and only because a peer too
// old or too new to share a handshake still has to be told which side to
// update (D16). It is bound into the Noise prologue, so editing it in flight
// fails the handshake rather than forcing a downgrade.
//
// Everything that identifies anyone — device name, device id, app versions,
// both long-term keys, the Mac's host name — is inside the Noise payloads. On
// the LAN that hides it from anyone on the network; on the relay path it hides
// it from the relay, which authenticates for BILLING and never for TRUST
// (D5/D13).

public struct Hello: Codable, Sendable, Equatable {
    /// Wire-protocol version (`ProtocolVersion.current`).
    public let protocolVersion: Int
    /// Noise IK message 1.
    public let handshake: Data

    public init(protocolVersion: Int = ProtocolVersion.current, handshake: Data) {
        self.protocolVersion = protocolVersion
        self.handshake = handshake
    }
}

public struct HelloAck: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    /// Noise IK message 2.
    public let handshake: Data

    public init(protocolVersion: Int = ProtocolVersion.current, handshake: Data) {
        self.protocolVersion = protocolVersion
        self.handshake = handshake
    }
}

/// Reads only the version out of a `Hello`/`HelloAck`.
///
/// Decoding the full message is exactly what fails when the peer speaks a
/// different version, so the version has to be readable on its own — that is
/// what lets the refusal say *which side* to update instead of the connection
/// silently dying (D16).
public struct HandshakeVersionProbe: Decodable, Sendable {
    public let protocolVersion: Int
}

/// The phone's identity, sealed inside Noise message 1.
public struct HelloIdentity: Codable, Sendable, Equatable {
    /// Marketing version of the sending build, e.g. "0.4.2". Diagnostics only —
    /// never branch on this, branch on `protocolVersion`.
    public let appVersion: String
    /// Stable per-install id. A label for the device list — **not** the
    /// credential. The credential is the Noise static key, which the handshake
    /// proves possession of.
    public let deviceID: UUID
    /// Human-readable, for the desktop's paired-device list. e.g. "Marko's iPhone"
    public let deviceName: String
    /// Set ONLY on the first connection after scanning a QR — identifies which
    /// displayed code is being redeemed.
    public let pairingID: String?
    /// `RemotePairing.pairingProof` — an HMAC, keyed by the QR's one-time
    /// secret, over this handshake's hash. Proves the sender saw the code.
    public let pairingProof: Data?

    public init(appVersion: String, deviceID: UUID, deviceName: String,
                pairingID: String? = nil, pairingProof: Data? = nil) {
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairingID = pairingID
        self.pairingProof = pairingProof
    }
}

/// The Mac's side, sealed inside Noise message 2.
public struct HelloAckPayload: Codable, Sendable, Equatable {
    public let appVersion: String
    /// The Mac's name, shown in Go's host picker. e.g. "Markos-MacBook-Pro"
    public let hostName: String
    /// What this desktop build will actually honour *for this device*. Lets Go
    /// hide affordances it knows the other end cannot serve, rather than
    /// surfacing a failure after the user taps. Authenticated now that it rides
    /// inside the handshake — v1 sent it in the clear, where anyone in the path
    /// could edit it.
    public let capabilities: Set<Capability>

    public init(appVersion: String, hostName: String, capabilities: Set<Capability>) {
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
