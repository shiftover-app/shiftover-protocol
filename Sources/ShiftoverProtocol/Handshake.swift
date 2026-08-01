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
    /// Stable per-device identity. **Self-asserted — never trust it alone.**
    public let deviceID: UUID
    /// Human-readable, for the desktop's paired-device list. e.g. "Marko's iPhone"
    public let deviceName: String

    /// The device's long-term X25519 public key (32 bytes).
    ///
    /// **This is the credential.** On a return connection the Mac finds the
    /// paired device by matching this, so possession of the corresponding
    /// private key is what authenticates — not `deviceID`, which any client can
    /// simply claim.
    public let publicKey: Data

    /// Fresh 32-byte per-session value, feeding the HKDF salt alongside the
    /// Mac's counterpart. Without it every session between a given pair would
    /// reuse one key while the frame counters restarted from zero — which is
    /// precisely the nonce reuse the per-direction key split exists to prevent.
    public let sessionNonce: Data

    /// Set ONLY on the first connection after scanning a QR — identifies which
    /// displayed code is being redeemed. `nil` on every later connection.
    public let pairingID: String?

    /// HMAC over both public keys + `pairingID`, keyed by the QR's one-time
    /// secret. This is what makes a man-in-the-middle fail: an attacker who
    /// substitutes a public key cannot recompute the tag without the secret,
    /// and the secret only ever appeared on the Mac's screen.
    public let pairingTag: Data?

    public init(protocolVersion: Int = ProtocolVersion.current,
                appVersion: String,
                deviceID: UUID,
                deviceName: String,
                publicKey: Data,
                sessionNonce: Data,
                pairingID: String? = nil,
                pairingTag: Data? = nil) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.sessionNonce = sessionNonce
        self.pairingID = pairingID
        self.pairingTag = pairingTag
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
    /// The Mac's half of the session-key salt. See `Hello.sessionNonce`.
    public let sessionNonce: Data

    public init(protocolVersion: Int = ProtocolVersion.current,
                appVersion: String,
                hostName: String,
                capabilities: Set<Capability>,
                sessionNonce: Data) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.hostName = hostName
        self.capabilities = capabilities
        self.sessionNonce = sessionNonce
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
