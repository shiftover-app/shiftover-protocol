// MARK: - Usage push — the lock-screen usage widget, kept current by the Mac
//
// The phone's usage widget draws from a cache only the app can fill, and while
// the app is closed it fills it only when iOS grants a background refresh —
// often once an hour or two, never after a force-quit. So the Mac, which polls
// the providers anyway, sends the figures to the phone in a background push
// when what the widget draws changes, and the phone writes them straight into
// that cache: no connection back to the Mac, which a background wake has
// neither the time nor the network to make reliably.
//
// Sealed like an agent push (`PushSealing`: HPKE auth mode, Mac to phone), but
// under its own `info` label, so a usage box can never be opened as a
// notification or the other way round. A phone from before this box simply
// fails to open it and drops it.

import CryptoKit
import Foundation

/// The figures a usage push carries: the same `ProviderUsageDTO`s the
/// `.providerUsage` RPC returns.
public struct UsagePushContent: Codable, Sendable, Equatable {
    public let providers: [ProviderUsageDTO]
    /// When the Mac sealed it. The phone drops a box older than
    /// `UsagePushSealing.maxAge`, so a relay that held one back cannot put old
    /// figures over newer ones.
    public let sentAt: Date

    public init(providers: [ProviderUsageDTO], sentAt: Date = Date()) {
        self.providers = providers
        self.sentAt = sentAt
    }
}

public enum UsagePushSealing {

    static let info = Data("shiftover-usage-push/v1".utf8)

    /// A box older than this is dropped rather than written.
    public static let maxAge: TimeInterval = 60 * 60

    /// The most the sealed JSON may weigh. APNs caps a payload at 4 KB, and
    /// base64, the AEAD tag and the envelope cost about a third on top.
    public static let maxPlaintextBytes = 2_800

    /// Seals `content` to the phone, authenticated as the Mac. Window details
    /// (free text, such as Cursor's dollar figures) are dropped if that is what
    /// it takes to fit; a report that still does not fit is refused rather
    /// than cut short, since the phone replaces this Mac's figures wholesale
    /// and a missing provider would vanish from its widget.
    public static func seal(_ content: UsagePushContent, toPhoneKey phoneKey: Data,
                            from mac: RemoteIdentityKey) throws -> SealedPush {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey) else {
            throw PushSealing.SealError.invalidKey
        }
        guard let plaintext = fitted(content) else { throw PushSealing.SealError.sealFailed }
        return try PushSealing.sealData(plaintext, info: info, to: recipient, from: mac)
    }

    /// The encoded content within `maxPlaintextBytes`, or `nil`.
    static func fitted(_ content: UsagePushContent) -> Data? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(content) else { return nil }
        if data.count <= maxPlaintextBytes { return data }
        let trimmed = UsagePushContent(providers: content.providers.map { provider in
            var provider = provider
            provider.windows = provider.windows.map { window in
                var window = window
                window.detail = nil
                return window
            }
            return provider
        }, sentAt: content.sentAt)
        guard let smaller = try? encoder.encode(trimmed), smaller.count <= maxPlaintextBytes else { return nil }
        return smaller
    }

    /// Opens a usage box on the phone, returning its content and the key of
    /// the paired Mac that sealed it. `nil` if no paired Mac sealed it, it was
    /// tampered with, it is an agent push, or it is older than `maxAge`.
    public static func open(_ sealed: SealedPush, with phone: RemoteIdentityKey,
                            fromAnyOf macKeys: [Data], now: Date = Date())
    -> (content: UsagePushContent, macKey: Data)? {
        guard let (plaintext, macKey) = PushSealing.openData(sealed, info: info, with: phone, fromAnyOf: macKeys),
              let content = try? JSONDecoder().decode(UsagePushContent.self, from: plaintext),
              now.timeIntervalSince(content.sentAt) <= maxAge,
              content.sentAt.timeIntervalSince(now) <= 60 else { return nil }
        return (content, macKey)
    }
}
