// MARK: - Noise (the handshake under every Shiftover remote connection)
//
// An implementation of exactly one Noise protocol:
//
//     Noise_IK_25519_ChaChaPoly_SHA256
//
//         <- s
//         ...
//         -> e, es, s, ss
//         <- e, ee, se
//
// The phone is the INITIATOR — it already holds the Mac's static key, read off
// the pairing QR — and the Mac is the RESPONDER.
//
// ── Why Noise rather than the hand-built handshake it replaced ──────────
//
// v1 sent `Hello` in the clear (device name, both long-term keys) and derived
// session keys from the static-static agreement plus two nonces. That had three
// gaps, all closed here:
//
//   • Metadata. A LAN observer — and, on the relay path, the relay itself —
//     read the device name and both identity keys. IK encrypts the initiator's
//     static key and every payload, so only the ephemeral key is in the clear.
//   • Forward secrecy. Every session key was a function of the two long-term
//     keys, so a phone key recovered later decrypted every recorded session.
//     The `ee` agreement makes each session key depend on keys that are thrown
//     away when the handshake ends.
//   • Replay. Frames carried their own nonce and any authentic frame opened,
//     so a captured frame — a keystroke, a merge — could be sent again within
//     the session. Noise transport nonces are IMPLICIT: a frame opens only at
//     the exact position it was sealed for.
//
// ── Why implement it rather than depend on a library ─────────────────────
//
// This package is zero-dependency by design (see Package.swift), and CryptoKit
// already supplies every primitive: X25519, ChaChaPoly, SHA-256, HMAC. What is
// written here is the Noise *state machine*, which is small and exhaustively
// specified — and it is checked byte-for-byte against the published cacophony
// test vector for this exact protocol name (`NoiseTests`), so it is verified
// against the spec rather than against itself.
//
// One deliberate deviation, in the transport phase only: Noise caps a message at
// 65,535 bytes because it assumes it owns the framing. Here the WebSocket message
// is the frame, and a terminal backfill can exceed 64 KB, so `NoiseCipher` does
// not enforce that cap. The cipher construction is unchanged.

import CryptoKit
import Foundation

public enum NoiseError: Error, Equatable, Sendable {
    /// Too short, or not the shape this handshake stage expects.
    case malformedMessage
    /// An AEAD open failed: wrong key, tampering, truncation, or a frame
    /// presented at the wrong position (a replay or a reorder).
    case decryptFailed
    /// A public key that X25519 would not accept.
    case invalidKey
    /// 2^64 − 1 messages under one key. Unreachable in practice, and loud
    /// rather than a silent wrap to a reused nonce.
    case nonceExhausted
    /// A handshake method called out of order.
    case outOfOrder
}

// MARK: - CipherState

/// One direction of a finished Noise session: a key and an implicit counter.
///
/// **A reference type on purpose.** The counter must advance exactly once per
/// message for the life of the connection. A struct copied into a dictionary
/// and back would fork it into two sequences, and a reused nonce is the one
/// failure ChaChaPoly does not survive.
public final class NoiseCipher: @unchecked Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private let lock = NSLock()

    /// Noise reserves 2^64 − 1; stopping one short of it keeps the check
    /// simple and the failure explicit.
    static let maxNonce: UInt64 = .max

    init(key: Data) {
        self.key = SymmetricKey(data: key)
    }

    /// How many messages this direction has sealed or opened.
    public var messageCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return counter
    }

    /// Seals the next message in this direction.
    public func encrypt(_ plaintext: Data, associatedData: Data = Data()) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard counter < Self.maxNonce else { throw NoiseError.nonceExhausted }
        let sealed = try Noise.seal(plaintext, key: key, counter: counter, ad: associatedData)
        counter += 1
        return sealed
    }

    /// Opens the next message in this direction.
    ///
    /// The counter advances **only on success**. A forged or corrupted frame
    /// therefore cannot desynchronise the stream: it fails, and the next
    /// authentic frame still opens at the position it was sealed for. A
    /// *replayed* authentic frame fails for the same reason — its position is
    /// already behind us.
    public func decrypt(_ ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard counter < Self.maxNonce else { throw NoiseError.nonceExhausted }
        let plaintext = try Noise.open(ciphertext, key: key, counter: counter, ad: associatedData)
        counter += 1
        return plaintext
    }
}

// MARK: - Primitives

enum Noise {
    static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    static let dhLength = 32
    static let hashLength = 32
    static let tagLength = 16

    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's two-output HKDF (§4.3), built on HMAC-SHA256 with the chaining
    /// key as the HMAC key. Not RFC 5869's API shape, so CryptoKit's `HKDF`
    /// cannot stand in for it directly.
    static func hkdf(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let tempKey = hmac(key: chainingKey, inputKeyMaterial)
        let output1 = hmac(key: tempKey, Data([0x01]))
        let output2 = hmac(key: tempKey, output1 + Data([0x02]))
        return (output1, output2)
    }

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Data) throws -> Data {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
        else { throw NoiseError.invalidKey }
        return secret.withUnsafeBytes { Data($0) }
    }

    /// 32 zero bits, then the counter as a LITTLE-endian 64-bit integer — the
    /// ChaChaPoly nonce encoding Noise specifies (§12.3).
    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, counter: UInt64, ad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(counter), authenticating: ad)
        return box.ciphertext + box.tag
    }

    static func open(_ ciphertext: Data, key: SymmetricKey, counter: UInt64, ad: Data) throws -> Data {
        guard ciphertext.count >= tagLength else { throw NoiseError.decryptFailed }
        let body = ciphertext.prefix(ciphertext.count - tagLength)
        let tag = ciphertext.suffix(tagLength)
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: body, tag: tag),
              let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: ad)
        else { throw NoiseError.decryptFailed }
        return plaintext
    }
}

// MARK: - SymmetricState

/// Noise §5.2: the chaining key, the handshake hash, and the handshake-phase
/// cipher key. A value type is safe here — it lives inside one handshake object
/// and is never shared.
struct NoiseSymmetricState {
    private(set) var chainingKey: Data
    private(set) var handshakeHash: Data
    private var key: SymmetricKey?
    private var counter: UInt64 = 0

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        handshakeHash = name.count <= Noise.hashLength
            ? name + Data(count: Noise.hashLength - name.count)
            : Noise.hash(name)
        chainingKey = handshakeHash
    }

    mutating func mixHash(_ data: Data) {
        handshakeHash = Noise.hash(handshakeHash + data)
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (ck, tempKey) = Noise.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = ck
        key = SymmetricKey(data: tempKey)
        counter = 0
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key else {
            mixHash(plaintext)
            return plaintext
        }
        let ciphertext = try Noise.seal(plaintext, key: key, counter: counter, ad: handshakeHash)
        counter += 1
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key else {
            mixHash(ciphertext)
            return ciphertext
        }
        let plaintext = try Noise.open(ciphertext, key: key, counter: counter, ad: handshakeHash)
        counter += 1
        mixHash(ciphertext)
        return plaintext
    }

    /// Initiator→responder first, responder→initiator second (Noise §5.2).
    func split() -> (NoiseCipher, NoiseCipher) {
        let (k1, k2) = Noise.hkdf(chainingKey: chainingKey, inputKeyMaterial: Data())
        return (NoiseCipher(key: k1), NoiseCipher(key: k2))
    }
}

// MARK: - Finished session

/// Both directions of a completed handshake, from one side's point of view.
public struct NoiseTransport: @unchecked Sendable {
    /// Seals what this side sends.
    public let send: NoiseCipher
    /// Opens what this side receives.
    public let receive: NoiseCipher
    /// The final handshake hash. Identical on both sides of one session and
    /// unique to it — usable as a channel binding.
    public let handshakeHash: Data
}

// MARK: - IK initiator (the phone)

public final class NoiseIKInitiator {
    private var state: NoiseSymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let localEphemeral: Curve25519.KeyAgreement.PrivateKey
    private let remoteStatic: Data
    private var stage = 0

    /// - Parameters:
    ///   - prologue: bound into the handshake hash; must match the responder's
    ///     byte for byte, or message 1 fails to open.
    ///   - staticKey: this device's long-term key.
    ///   - remoteStaticKey: the responder's long-term public key, known in
    ///     advance (the `<- s` pre-message).
    ///   - ephemeralKey: fresh per handshake. Injectable ONLY so the test vector
    ///     can pin it; production callers must take the default.
    public init(prologue: Data,
                staticKey: Curve25519.KeyAgreement.PrivateKey,
                remoteStaticKey: Data,
                ephemeralKey: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
        guard remoteStaticKey.count == Noise.dhLength,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticKey)) != nil
        else { throw NoiseError.invalidKey }
        localStatic = staticKey
        localEphemeral = ephemeralKey
        remoteStatic = remoteStaticKey
        state = NoiseSymmetricState(protocolName: Noise.protocolName)
        state.mixHash(prologue)
        state.mixHash(remoteStaticKey)   // <- s
    }

    /// Message 1: `e, es, s, ss`, then the payload.
    ///
    /// The payload is built by a closure that receives the handshake hash as it
    /// stands just before the payload is sealed. That value is unique to this
    /// handshake and covers both static keys, which is what lets a pairing
    /// proof be bound to it (see `RemotePairing.pairingProof`).
    public func writeMessage1(payload makePayload: (_ handshakeHash: Data) throws -> Data) throws -> Data {
        guard stage == 0 else { throw NoiseError.outOfOrder }
        stage = 1

        let ephemeralPublic = localEphemeral.publicKey.rawRepresentation
        var message = ephemeralPublic
        state.mixHash(ephemeralPublic)                                        // e
        state.mixKey(try Noise.dh(localEphemeral, remoteStatic))              // es
        message += try state.encryptAndHash(localStatic.publicKey.rawRepresentation) // s
        state.mixKey(try Noise.dh(localStatic, remoteStatic))                 // ss
        message += try state.encryptAndHash(try makePayload(state.handshakeHash))
        return message
    }

    /// Message 2: `e, ee, se`, then the payload. Completes the handshake.
    public func readMessage2(_ message: Data) throws -> (payload: Data, transport: NoiseTransport) {
        guard stage == 1 else { throw NoiseError.outOfOrder }
        stage = 2
        guard message.count >= Noise.dhLength + Noise.tagLength else {
            throw NoiseError.malformedMessage
        }
        let remoteEphemeral = Data(message.prefix(Noise.dhLength))
        state.mixHash(remoteEphemeral)                                        // e
        state.mixKey(try Noise.dh(localEphemeral, remoteEphemeral))           // ee
        state.mixKey(try Noise.dh(localStatic, remoteEphemeral))              // se
        let payload = try state.decryptAndHash(Data(message.dropFirst(Noise.dhLength)))

        let (initiatorToResponder, responderToInitiator) = state.split()
        return (payload, NoiseTransport(send: initiatorToResponder,
                                        receive: responderToInitiator,
                                        handshakeHash: state.handshakeHash))
    }
}

// MARK: - IK responder (the Mac)

/// What the responder learns from message 1.
public struct NoiseIKFirstMessage: Sendable {
    /// The initiator's long-term public key — now PROVEN, not claimed: the
    /// payload only opens if the sender holds its private half (`ss`).
    public let remoteStaticKey: Data
    /// The handshake hash as the initiator saw it just before sealing the
    /// payload. The value a pairing proof is checked against.
    public let handshakeHashBeforePayload: Data
    public let payload: Data
}

public final class NoiseIKResponder {
    private var state: NoiseSymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let localEphemeral: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeral: Data?
    private var remoteStatic: Data?
    private var stage = 0

    public init(prologue: Data,
                staticKey: Curve25519.KeyAgreement.PrivateKey,
                ephemeralKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        localStatic = staticKey
        localEphemeral = ephemeralKey
        state = NoiseSymmetricState(protocolName: Noise.protocolName)
        state.mixHash(prologue)
        state.mixHash(staticKey.publicKey.rawRepresentation)   // <- s
    }

    /// Message 1: `e, es, s, ss`, then the payload.
    public func readMessage1(_ message: Data) throws -> NoiseIKFirstMessage {
        guard stage == 0 else { throw NoiseError.outOfOrder }
        stage = 1
        let encryptedStaticLength = Noise.dhLength + Noise.tagLength
        guard message.count >= Noise.dhLength + encryptedStaticLength + Noise.tagLength else {
            throw NoiseError.malformedMessage
        }

        var cursor = message.startIndex
        func take(_ count: Int) -> Data {
            let slice = message[cursor..<message.index(cursor, offsetBy: count)]
            cursor = message.index(cursor, offsetBy: count)
            return Data(slice)
        }

        let ephemeral = take(Noise.dhLength)
        state.mixHash(ephemeral)                                              // e
        state.mixKey(try Noise.dh(localStatic, ephemeral))                    // es
        let staticKey = try state.decryptAndHash(take(encryptedStaticLength)) // s
        state.mixKey(try Noise.dh(localStatic, staticKey))                    // ss
        let hashBeforePayload = state.handshakeHash
        let payload = try state.decryptAndHash(Data(message[cursor...]))

        remoteEphemeral = ephemeral
        remoteStatic = staticKey
        return NoiseIKFirstMessage(remoteStaticKey: staticKey,
                                   handshakeHashBeforePayload: hashBeforePayload,
                                   payload: payload)
    }

    /// Message 2: `e, ee, se`, then the payload. Completes the handshake.
    public func writeMessage2(payload: Data) throws -> (message: Data, transport: NoiseTransport) {
        guard stage == 1, let remoteEphemeral, let remoteStatic else { throw NoiseError.outOfOrder }
        stage = 2

        let ephemeralPublic = localEphemeral.publicKey.rawRepresentation
        var message = ephemeralPublic
        state.mixHash(ephemeralPublic)                                        // e
        state.mixKey(try Noise.dh(localEphemeral, remoteEphemeral))           // ee
        state.mixKey(try Noise.dh(localEphemeral, remoteStatic))              // se
        message += try state.encryptAndHash(payload)

        let (initiatorToResponder, responderToInitiator) = state.split()
        return (message, NoiseTransport(send: responderToInitiator,
                                        receive: initiatorToResponder,
                                        handshakeHash: state.handshakeHash))
    }
}
