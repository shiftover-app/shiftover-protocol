import Foundation

// MARK: - Protocol version (PLAN_45 D16)
//
// Three components ship through three INDEPENDENT release channels:
//
//   • Shiftover (desktop) → Sparkle    — user updates when they choose
//   • Shiftover Go (iOS)  → App Store  — review latency *and* user choice
//   • Shiftover Cloud     → wrangler   — instant, on push
//
// No repo layout can make those land together. A user on a months-old Go build
// talking to a fresh desktop is routine, not an edge case. So version skew is a
// permanent operating condition, and the protocol must DETECT it rather than
// fail in some mysterious downstream way.
//
// The first shipped Go build sets this floor forever — an app already on
// someone's phone cannot be taught a handshake it never knew about.

public enum ProtocolVersion {
    /// The version this build speaks.
    ///
    /// 2 replaced v1's cleartext handshake with Noise IK. Nothing had shipped,
    /// but development builds of Go existed on devices, and bumping is what
    /// lets them be told "update" rather than silently fail to handshake.
    public static let current: Int = 2

    /// Oldest peer version this build still accepts. Widen the window rather
    /// than bumping `current` whenever a change is additive; bump `current`
    /// AND this together only for a deliberate break.
    ///
    /// Policy: support N-2 — from the first version that actually ships. v1
    /// never did, and its handshake cannot be spoken safely, so the floor sits
    /// at 2 and the window is degenerate until a later version ships.
    public static let minimumSupported: Int = 2
}

/// The outcome of comparing a peer's advertised version against ours.
///
/// Deliberately carries the numbers, not just a Bool: the UI has to tell the
/// user *which side* to update, and "incompatible" alone cannot.
public enum VersionCompatibility: Equatable, Sendable {
    case compatible(negotiated: Int)
    /// The peer is behind our floor — it must update.
    case peerTooOld(peer: Int, minimumSupported: Int)
    /// The peer is ahead of us — *we* must update.
    case peerTooNew(peer: Int, current: Int)

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }
}

extension ProtocolVersion {
    /// Pure compatibility check. Both ends run this against the other's `Hello`.
    ///
    /// The negotiated version is `min(current, peer)`, so a newer peer speaking
    /// down to us stays within what we understand.
    public static func check(peerVersion: Int) -> VersionCompatibility {
        if peerVersion < minimumSupported {
            return .peerTooOld(peer: peerVersion, minimumSupported: minimumSupported)
        }
        if peerVersion > current {
            return .peerTooNew(peer: peerVersion, current: current)
        }
        return .compatible(negotiated: min(current, peerVersion))
    }
}

extension VersionCompatibility {
    /// A user-facing refusal that names the action to take.
    ///
    /// D16 requires an *actionable* refusal — never a silent failure and never
    /// a half-working session. `nil` when compatible.
    ///
    /// - Parameter localSideIsPhone: whether the side rendering this message is
    ///   the phone. Determines whether "you" means the App Store or the Mac.
    public func refusalMessage(localSideIsPhone: Bool) -> String? {
        switch self {
        case .compatible:
            return nil
        case .peerTooOld:
            return localSideIsPhone
                ? "This Mac is running an older Shiftover. Update it to continue."
                : "Shiftover Go is out of date. Update it in the App Store to continue."
        case .peerTooNew:
            return localSideIsPhone
                ? "Shiftover Go is out of date. Update it in the App Store to continue."
                : "This Mac is running an older Shiftover. Update it to continue."
        }
    }
}
