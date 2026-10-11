import CryptoKit
import Foundation

// MARK: - Presence proofs (PLAN_45 D9, enforced by the Mac)
//
// A phone with the write grant is a remote shell on the Mac. Go has always
// asked for Face ID before a write, but that check ran only on the phone, so
// the Mac was taking the phone's word for it. These proofs let the Mac check
// for itself.
//
// At pairing, the phone creates two P-256 keys in its Secure Enclave and sends
// their public halves inside the sealed handshake:
//
//   • **owner**: signs only after Face ID, Touch ID or the passcode. One proof
//     opens a `window` on that connection for every write, terminal input
//     included.
//   • **unlocked**: signs without a prompt, but only while the phone is
//     unlocked. Valid ONLY for a lock-screen answer (Allow / Deny / Reply on a
//     notification), and only for the exact answer it signs. iOS already
//     required the phone unlocked before running that action, and a prompt
//     cannot be shown from the lock screen.
//
// The Secure Enclave enforces both conditions, so a copy of the phone's pairing
// key (which has to stay readable while locked, for push) does not confer
// writes, and neither does an unlocked phone handed to someone who cannot pass
// Face ID or the passcode.
//
// Every proof is bound to its connection (the Noise handshake hash) and carries
// a counter that must increase on that connection, so one cannot be replayed on
// another connection or reused on the same one.

/// The public halves of the phone's two presence keys, as P-256 X9.63
/// (uncompressed, 65 bytes).
public struct PresenceKeys: Codable, Sendable, Equatable {
    public let owner: Data
    public let unlocked: Data

    public init(owner: Data, unlocked: Data) {
        self.owner = owner
        self.unlocked = unlocked
    }

    /// Both are valid P-256 points, and they are different keys. A phone that
    /// sent the same key twice would make the weaker level as strong as the
    /// stronger one, so the Mac refuses such a pair.
    public var isWellFormed: Bool {
        owner != unlocked
            && (try? P256.Signing.PublicKey(x963Representation: owner)) != nil
            && (try? P256.Signing.PublicKey(x963Representation: unlocked)) != nil
    }

    public func key(for level: PresenceLevel) -> Data {
        switch level {
        case .owner: return owner
        case .unlocked: return unlocked
        }
    }
}

public enum PresenceLevel: String, Codable, Sendable, Equatable {
    /// Face ID, Touch ID or the passcode, just now.
    case owner
    /// The phone was unlocked. Enough only for a lock-screen answer.
    case unlocked
}

/// One signed statement from the phone.
public struct PresenceAssertion: Codable, Sendable, Equatable {
    public let level: PresenceLevel
    /// Strictly increasing per connection, shared by both levels.
    public let counter: UInt64
    /// ECDSA P-256 over SHA-256, DER-encoded.
    public let signature: Data

    public init(level: PresenceLevel, counter: UInt64, signature: Data) {
        self.level = level
        self.counter = counter
        self.signature = signature
    }
}

public enum PresenceProof {

    /// How long one owner proof keeps writes open on its connection. Matches
    /// Go's own unlock window, so one Face ID covers a session of work.
    public static let window: TimeInterval = 5 * 60

    /// The exact bytes a phone signs.
    ///
    /// The domain tag and level keep a proof from being read as anything else,
    /// the handshake hash ties it to one connection, and the counter to one
    /// use. Every field before `binding` has a fixed length, so no two inputs
    /// produce the same bytes.
    public static func message(level: PresenceLevel, counter: UInt64,
                               handshakeHash: Data, binding: Data = Data()) -> Data {
        var message = Data("shiftover-presence/v1".utf8)
        message.append(0)
        message.append(Data(level.rawValue.utf8))
        message.append(0)
        message.append(SHA256.hash(data: handshakeHash).withUnsafeBytes { Data($0) })
        withUnsafeBytes(of: counter.bigEndian) { message.append(contentsOf: $0) }
        message.append(binding)
        return message
    }

    /// What a lock-screen answer signs: the whole request, field by field, so
    /// a proof for "Allow" cannot be spent on "Deny", on another worktree, or
    /// on another notification.
    ///
    /// `nil` for every method that cannot be answered from a notification —
    /// which is also the Mac's test for whether an `unlocked` proof may be
    /// considered at all.
    public static func notificationBinding(for method: RPCMethod) -> Data? {
        switch method {
        case .answerPermission(let worktreeID, let allow, let sentAt?):
            var binding = Data("answerPermission".utf8)
            binding.append(0)
            binding.append(uuidBytes(worktreeID))
            binding.append(allow ? 1 : 0)
            binding.append(milliseconds(sentAt))
            return binding
        case .replyToAgent(let worktreeID, let text, let sentAt?):
            var binding = Data("replyToAgent".utf8)
            binding.append(0)
            binding.append(uuidBytes(worktreeID))
            binding.append(milliseconds(sentAt))
            binding.append(SHA256.hash(data: Data(text.utf8)).withUnsafeBytes { Data($0) })
            return binding
        default:
            return nil
        }
    }

    /// Checks one assertion against the key registered for its level.
    public static func verify(_ assertion: PresenceAssertion, keys: PresenceKeys,
                              handshakeHash: Data, binding: Data = Data()) -> Bool {
        guard let key = try? P256.Signing.PublicKey(
                  x963Representation: keys.key(for: assertion.level)),
              let signature = try? P256.Signing.ECDSASignature(
                  derRepresentation: assertion.signature)
        else { return false }
        let message = message(level: assertion.level, counter: assertion.counter,
                              handshakeHash: handshakeHash, binding: binding)
        return key.isValidSignature(signature, for: message)
    }

    private static func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    /// Whole milliseconds since 1970, big-endian. A `Date` crosses the wire as
    /// a JSON double, so both ends round it the same way rather than trusting
    /// the double to survive bit for bit.
    private static func milliseconds(_ date: Date) -> Data {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return withUnsafeBytes(of: ms.bigEndian) { Data($0) }
    }
}
