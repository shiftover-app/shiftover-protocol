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
// importantly, no hand-rolled primitives.

import CryptoKit
import Foundation

/// Directional session keys for one connection.
///
/// **Each direction gets its OWN key.** That is not belt-and-braces: ChaChaPoly
/// nonces are counters here, and a counter reused under the same key is a
/// catastrophic failure (it leaks the XOR of two plaintexts and forges the
/// authenticator). Two peers counting independently from zero under one shared
/// key would collide on literally every frame. Separate keys make that
/// structurally impossible rather than something a future refactor must
/// remember.
public struct RemoteSessionKeys: Sendable {
    /// Seals what the Mac sends; opens what the phone receives.
    public let macToPhone: SymmetricKey
    /// Seals what the phone sends; opens what the Mac receives.
    public let phoneToMac: SymmetricKey

    /// Derives both directions from a completed X25519 agreement.
    ///
    /// - Parameters:
    ///   - sharedSecret: output of `Curve25519.KeyAgreement` between the two
    ///     devices' long-term identity keys, established at pairing.
    ///   - macNonce: the Mac's fresh 32-byte per-session value.
    ///   - phoneNonce: the phone's.
    ///
    /// The nonces are the reason a session key is not simply a function of the
    /// two identity keys — without them, every session between a given pair
    /// would reuse the same key while the frame counters restarted from zero,
    /// reintroducing exactly the collision the direction split prevents.
    public static func derive(
        sharedSecret: SharedSecret,
        macNonce: Data,
        phoneNonce: Data
    ) -> RemoteSessionKeys {
        // Salt binds the keys to THIS session; info separates the directions.
        let salt = macNonce + phoneNonce
        return RemoteSessionKeys(
            macToPhone: sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt,
                sharedInfo: Data("shiftover-remote-v1-mac-to-phone".utf8),
                outputByteCount: 32),
            phoneToMac: sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt,
                sharedInfo: Data("shiftover-remote-v1-phone-to-mac".utf8),
                outputByteCount: 32))
    }
}

/// Seals and opens frames for one direction, holding that direction's counter.
///
/// Not a value type on purpose — the counter must advance for the whole
/// connection, and a copied struct would silently fork it into two sequences
/// that both reuse nonces.
public final class RemoteFrameCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Hard ceiling on frames per key. The nonce here is a 64-bit counter in a
    /// 96-bit field, so wrapping is not a practical risk — but making
    /// exhaustion an explicit, loud failure beats a silent wrap to zero, which
    /// would be the worst outcome and the hardest to notice.
    public static let maxFramesPerKey: UInt64 = .max - 1

    public enum CipherError: Error, Equatable {
        case counterExhausted
        case sealFailed
        case openFailed
    }

    /// Encrypts one frame. The returned bytes are `nonce || ciphertext || tag`
    /// — ChaChaPoly's combined representation.
    public func seal(_ plaintext: Data) throws -> Data {
        guard counter < Self.maxFramesPerKey else { throw CipherError.counterExhausted }
        let boxNonce = try Self.nonce(from: counter)
        counter += 1

        guard let sealed = try? ChaChaPoly.seal(plaintext, using: key, nonce: boxNonce) else {
            throw CipherError.sealFailed
        }
        return sealed.combined
    }

    /// Decrypts one frame.
    ///
    /// The nonce travels in the combined blob rather than being re-derived from
    /// a local counter, so an out-of-order or dropped frame does not
    /// desynchronise the stream. Authenticity is what actually matters, and
    /// ChaChaPoly's tag provides it — a forged or tampered frame fails to open
    /// regardless of what nonce it claims.
    public func open(_ combined: Data) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plaintext = try? ChaChaPoly.open(box, using: key)
        else { throw CipherError.openFailed }
        return plaintext
    }

    /// Big-endian counter in the low 8 bytes of a 12-byte nonce.
    private static func nonce(from counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        return try ChaChaPoly.Nonce(data: bytes)
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

    /// Agrees with a peer's public key. `nil` for a malformed peer key rather
    /// than throwing — a bad key arrives from the network and is an
    /// untrusted-input condition, not a programming error.
    public func sharedSecret(withPeerPublicKey data: Data) -> SharedSecret? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }
        return secret
    }
}
