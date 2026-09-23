// MARK: - RemoteCrypto (PLAN_45 D5 — end-to-end encryption)
//
// Every frame between Shiftover and Shiftover Go is sealed here. The relay
// carries ciphertext and nothing else — not as a policy it promises to follow,
// but because it is never given a key.
//
// ── Why this lives in the SHARED package ────────────────────────────────
//
// Both ends must derive byte-identical keys and count nonces the same way, so
// this is wire vocabulary as much as `Frame` is. It briefly lived in the macOS
// app target; writing the probe made the mistake obvious, since the phone needs
// exactly this code and cannot import the app.
//
// ── Why E2E even on the LAN ─────────────────────────────────────────────
//
// The relay path *requires* it: a Cloudflare Durable Object forwarding terminal
// bytes would otherwise be able to read API keys, secrets and source. Running
// the same sealing on the LAN path costs nothing and means there is exactly ONE
// code path to get right, rather than a hardened one and a "it's just the local
// network" one that quietly diverges.
//
// CryptoKit ships on macOS and iOS, so this adds no dependency — and, more
// importantly, no hand-rolled primitives. The handshake itself is Noise IK
// (`Noise.swift`), verified against the published test vector.

import CryptoKit
import Foundation

/// One finished, encrypted connection, from one side's point of view.
///
/// Everything after the handshake goes through `seal` / `open`. The nonces are
/// implicit and position-bound (see `NoiseCipher`), so a frame opens only once
/// and only in the order it was sealed — a replayed or reordered frame fails
/// exactly as a forged one does. The WebSocket underneath is ordered and
/// reliable, so an honest peer never trips that.
///
/// **A reference type on purpose**, for the same reason as `NoiseCipher`: the
/// counters inside must advance once per frame for the life of the connection,
/// and a copied value would fork them.
public final class RemoteChannel: @unchecked Sendable {
    private let transport: NoiseTransport

    init(transport: NoiseTransport) {
        self.transport = transport
    }

    /// Unique to this session and identical on both ends. Usable as a channel
    /// binding — e.g. to prove, inside the channel, which session a token
    /// belongs to.
    public var handshakeHash: Data { transport.handshakeHash }

    /// Frames this side has sealed. A `0` means the peer has proven nothing
    /// yet beyond being able to complete a handshake.
    public var sentCount: UInt64 { transport.send.messageCount }
    /// Frames this side has opened.
    public var receivedCount: UInt64 { transport.receive.messageCount }

    public func seal(_ plaintext: Data) throws -> Data {
        try transport.send.encrypt(plaintext)
    }

    public func open(_ ciphertext: Data) throws -> Data {
        try transport.receive.decrypt(ciphertext)
    }
}

/// Why a handshake could not complete.
///
/// Deliberately coarse on the Mac's side: every one of these ends in the same
/// silent disconnect, because telling an unauthenticated peer *which* check
/// failed tells a prober which half of its guess was right.
public enum RemoteHandshakeError: Error, Equatable, Sendable {
    /// The peer's version is outside our window. Carries the numbers so the
    /// caller can say which side to update.
    case incompatible(VersionCompatibility)
    /// A Noise message would not open or was malformed — wrong key, tampering,
    /// or not a Shiftover peer at all.
    case cryptographic(NoiseError)
    /// The sealed payload opened but is not a payload this build understands.
    case malformedPayload
    /// The code being redeemed was issued by a different Mac than the one
    /// being dialled. A programming error on the phone, caught before any
    /// bytes leave it.
    case codeDoesNotMatchHost
}

/// The Shiftover handshake on top of Noise IK. The desktop, Go and the probe all
/// run this one implementation, so the three can never disagree about a byte.
public enum RemoteHandshake {

    /// Bound into the Noise handshake hash. Carries the cleartext version, which
    /// is what makes editing that version in flight fail the handshake instead
    /// of forcing a downgrade.
    public static func prologue(protocolVersion: Int) -> Data {
        Data("shiftover-remote/v\(protocolVersion)".utf8)
    }

    // MARK: Phone

    /// The phone's half: builds `Hello`, completes on `HelloAck`.
    public final class Initiator {
        private let noise: NoiseIKInitiator
        private let macPublicKey: Data

        /// - Parameter macPublicKey: from the QR on first pairing, from the
        ///   pairing store thereafter. Knowing it in advance is what makes this
        ///   IK: the phone can encrypt its own identity to the Mac in the very
        ///   first message.
        public init(identity: RemoteIdentityKey, macPublicKey: Data) throws {
            do {
                noise = try NoiseIKInitiator(
                    prologue: RemoteHandshake.prologue(protocolVersion: ProtocolVersion.current),
                    staticKey: identity.privateKey,
                    remoteStaticKey: macPublicKey)
            } catch let error as NoiseError {
                throw RemoteHandshakeError.cryptographic(error)
            }
            self.macPublicKey = macPublicKey
        }

        /// Message 1. Pass `redeeming` on the first connection after scanning a
        /// code; its proof is bound to THIS handshake, so it cannot be lifted
        /// into another one.
        public func hello(appVersion: String, deviceID: UUID, deviceName: String,
                          redeeming code: RemotePairing.Code? = nil) throws -> Hello {
            if let code, code.publicKey != macPublicKey {
                throw RemoteHandshakeError.codeDoesNotMatchHost
            }
            do {
                let message = try noise.writeMessage1 { handshakeHash in
                    let identity = HelloIdentity(
                        appVersion: appVersion,
                        deviceID: deviceID,
                        deviceName: deviceName,
                        pairingID: code?.pairingID,
                        pairingProof: code.map {
                            RemotePairing.pairingProof(secret: $0.secret,
                                                       pairingID: $0.pairingID,
                                                       handshakeHash: handshakeHash)
                        })
                    return try JSONEncoder().encode(identity)
                }
                return Hello(handshake: message)
            } catch let error as NoiseError {
                throw RemoteHandshakeError.cryptographic(error)
            }
        }

        /// Message 2. Returns what the Mac said about itself and the open channel.
        public func finish(_ ack: HelloAck) throws -> (HelloAckPayload, RemoteChannel) {
            let compatibility = ProtocolVersion.check(peerVersion: ack.protocolVersion)
            guard compatibility.isCompatible else {
                throw RemoteHandshakeError.incompatible(compatibility)
            }
            let payload: Data
            let transport: NoiseTransport
            do {
                (payload, transport) = try noise.readMessage2(ack.handshake)
            } catch let error as NoiseError {
                throw RemoteHandshakeError.cryptographic(error)
            }
            guard let decoded = try? JSONDecoder().decode(HelloAckPayload.self, from: payload) else {
                throw RemoteHandshakeError.malformedPayload
            }
            return (decoded, RemoteChannel(transport: transport))
        }
    }

    // MARK: Mac

    /// What the Mac learns from a `Hello`, before deciding whether to accept it.
    public struct IncomingHello: Sendable {
        /// The phone's long-term public key, **proven** by the handshake — the
        /// payload only opens if the sender holds the private half. This, not
        /// `identity.deviceID`, is what a returning device is looked up by.
        public let phonePublicKey: Data
        public let identity: HelloIdentity
        /// What a pairing proof must have been computed over.
        public let handshakeHash: Data
    }

    /// The Mac's half: opens `Hello`, and — once the caller has decided the
    /// device is welcome — answers with `HelloAck`.
    public final class Responder {
        private let noise: NoiseIKResponder

        public init(identity: RemoteIdentityKey) {
            noise = NoiseIKResponder(
                prologue: RemoteHandshake.prologue(protocolVersion: ProtocolVersion.current),
                staticKey: identity.privateKey)
        }

        /// Opens message 1. Check the version FIRST (`HandshakeVersionProbe`)
        /// and refuse readably if it is out of range — this throws
        /// `.incompatible` too, but by then a refusal is all that is left to do.
        public func open(_ hello: Hello) throws -> IncomingHello {
            let compatibility = ProtocolVersion.check(peerVersion: hello.protocolVersion)
            guard compatibility.isCompatible else {
                throw RemoteHandshakeError.incompatible(compatibility)
            }
            let first: NoiseIKFirstMessage
            do {
                first = try noise.readMessage1(hello.handshake)
            } catch let error as NoiseError {
                throw RemoteHandshakeError.cryptographic(error)
            }
            guard let identity = try? JSONDecoder().decode(HelloIdentity.self, from: first.payload) else {
                throw RemoteHandshakeError.malformedPayload
            }
            return IncomingHello(phonePublicKey: first.remoteStaticKey,
                                 identity: identity,
                                 handshakeHash: first.handshakeHashBeforePayload)
        }

        /// Message 2. Only call once the device has been authorised.
        public func accept(_ payload: HelloAckPayload) throws -> (HelloAck, RemoteChannel) {
            do {
                let (message, transport) = try noise.writeMessage2(
                    payload: try JSONEncoder().encode(payload))
                return (HelloAck(handshake: message), RemoteChannel(transport: transport))
            } catch let error as NoiseError {
                throw RemoteHandshakeError.cryptographic(error)
            }
        }
    }
}

/// A device's long-term X25519 identity, generated once and reused across
/// pairings. The private half never leaves the device it was created on.
public struct RemoteIdentityKey {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    public init?(rawRepresentation: Data) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: rawRepresentation) else { return nil }
        privateKey = key
    }

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    public var rawRepresentation: Data { privateKey.rawRepresentation }
}
