// MARK: - Push (PLAN_45 D17 — the lock screen shows the question, the relay sees nothing)
//
// When an agent blocks, the Mac sends the phone a push that says what it is
// waiting for — "Allow Bash: rm -rf build?" — so it can be answered from the lock
// screen. That text is workspace content, and it travels through two parties
// that must not read it: Shiftover Cloud (which asks APNs to deliver) and Apple
// (which delivers). So the Mac seals it to the phone's long-term key with HPKE,
// and the phone's Notification Service Extension opens it on the device.
//
// ── Why HPKE rather than the Noise channel ──────────────────────────────
//
// A push is one message to a device that may have no live session at all —
// asleep in a pocket, app not running. There is nothing to run a handshake
// over, so it needs a one-shot sealed box to a known key: HPKE (RFC 9180), in
// **auth mode**, so the phone can check the box came from the Mac it paired
// with and not from anyone who merely knows its public key.
//
// It reuses the two identity keys the Noise handshake uses. The `info` label
// below separates the derivations, so the two protocols cannot be played
// against each other.
//
// ── What still leaks ────────────────────────────────────────────────────
//
// That a push happened, when, and roughly how long it was — unavoidable for a
// notification. Not which project, not which agent, not what it asked.

import CryptoKit
import Foundation

/// What the phone shows. Sealed end to end; never visible to the relay or APNs.
public struct PushContent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Waiting for input → "Reply".
        case input
        /// Waiting for approval → "Allow" / "Deny".
        case permission
        case done
        case error
    }

    public let kind: Kind
    public let worktreeID: UUID
    /// e.g. "shiftover · feat/relay"
    public let title: String
    public let subtitle: String?
    public let body: String
    /// When the Mac sealed it. The phone drops a push older than
    /// `PushSealing.maxAge`: a relay that held one back, or replayed one, must
    /// not be able to put a question on the lock screen that has long since
    /// been answered.
    public let sentAt: Date

    public init(kind: Kind, worktreeID: UUID, title: String, subtitle: String?,
                body: String, sentAt: Date = Date()) {
        self.kind = kind
        self.worktreeID = worktreeID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sentAt = sentAt
    }

    /// Category identifiers the phone registers actions under.
    public var categoryIdentifier: String { "shiftover.\(kind.rawValue)" }
}

/// A sealed `PushContent`, as it rides inside the APNs payload.
public struct SealedPush: Codable, Sendable, Equatable {
    /// HPKE encapsulated key.
    public let encapsulatedKey: Data
    public let ciphertext: Data

    public init(encapsulatedKey: Data, ciphertext: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }
}

public enum PushSealing {

    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let info = Data("shiftover-push/v1".utf8)

    /// A push older than this is dropped rather than shown.
    public static let maxAge: TimeInterval = 15 * 60

    /// The body is cut to this many UTF-8 bytes before sealing. APNs caps a
    /// payload at 4 KB, and base64 plus the envelope costs about a third on top.
    public static let maxBodyBytes = 1_800

    public enum SealError: Error, Equatable {
        case invalidKey
        case sealFailed
    }

    /// Seals `content` to the phone, authenticated as the Mac.
    public static func seal(_ content: PushContent, toPhoneKey phoneKey: Data,
                            from mac: RemoteIdentityKey) throws -> SealedPush {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey) else {
            throw SealError.invalidKey
        }
        let trimmed = PushContent(kind: content.kind, worktreeID: content.worktreeID,
                                  title: content.title, subtitle: content.subtitle,
                                  body: truncated(content.body, maxBytes: maxBodyBytes),
                                  sentAt: content.sentAt)
        do {
            var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite,
                                         info: info, authenticatedBy: mac.privateKey)
            let ciphertext = try sender.seal(try JSONEncoder().encode(trimmed))
            return SealedPush(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
        } catch {
            throw SealError.sealFailed
        }
    }

    /// Opens a push on the phone.
    ///
    /// Tries each paired Mac's key as the authenticated sender and returns the
    /// content with the key that verified — so the phone knows which Mac asked.
    /// `nil` if no paired Mac sealed it, it was tampered with, or it is older
    /// than `maxAge`.
    public static func open(_ sealed: SealedPush, with phone: RemoteIdentityKey,
                            fromAnyOf macKeys: [Data], now: Date = Date())
    -> (content: PushContent, macKey: Data)? {
        for macKey in macKeys {
            guard let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
                  var recipient = try? HPKE.Recipient(
                      privateKey: phone.privateKey, ciphersuite: ciphersuite, info: info,
                      encapsulatedKey: sealed.encapsulatedKey, authenticatedBy: sender),
                  let plaintext = try? recipient.open(sealed.ciphertext),
                  let content = try? JSONDecoder().decode(PushContent.self, from: plaintext)
            else { continue }
            guard now.timeIntervalSince(content.sentAt) <= maxAge else { return nil }
            return (content, macKey)
        }
        return nil
    }

    /// Cuts `text` to at most `maxBytes` of UTF-8 without splitting a character.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size + 3 <= maxBytes else { break }
            out.append(character)
            used += size
        }
        return out + "…"
    }
}
