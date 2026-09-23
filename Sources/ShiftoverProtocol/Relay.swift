import Foundation

// MARK: - Relay (Shiftover Cloud)
//
// The vocabulary both endpoints need to use the relay. The relay itself (a
// Cloudflare Durable Object, closed source) mirrors it in TypeScript; nothing
// here describes session content, because the relay never sees any — every
// binary message it carries is sealed by the Noise channel end to end.

/// Where a pairing meets on the relay, and the token that admits it.
///
/// Minted by the Mac, per paired phone, and handed over **inside** the
/// encrypted channel (`HelloAckPayload.relay`) — so it never exists anywhere
/// but on those two devices. The relay names the pairing's Durable Object by the
/// token's SHA-256 and never stores the token itself.
///
/// The token admits a socket to the pairing's relay and nothing more. Someone
/// who learned it could disrupt the pairing, never read it: they hold no key.
public struct RelayRoute: Codable, Sendable, Equatable {
    /// Base URL of the relay, e.g. `wss://cloud.shiftover.app`.
    public let url: String
    /// 32 random bytes, base64url without padding.
    public let token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    /// Mints a fresh token for a new pairing.
    public static func mintToken() -> String {
        RemotePairing.base64url(RemotePairing.randomBytes(32))
    }

    /// The header that carries the token. A header rather than a query
    /// parameter so it never lands in a URL log.
    public static let headerName = "x-shiftover-route"

    public enum Role: String, Sendable {
        case mac
        case phone
    }

    /// The WebSocket URL to dial for `role`, or `nil` if `url` is not a usable
    /// `ws://` / `wss://` base.
    public func connectURL(role: Role) -> URL? {
        guard var components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws",
              components.host?.isEmpty == false
        else { return nil }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/v1/connect"
        components.queryItems = [URLQueryItem(name: "role", value: role.rawValue)]
        return components.url
    }
}

/// The only messages the relay originates: bare ASCII text frames announcing
/// who is present. Everything else on the socket is a binary Shiftover frame.
///
/// The relay tells each side when the other arrives or really leaves, and tells
/// a newcomer whether its peer is already there. A socket merely *replaced* by a
/// reconnect of the same role is never announced as gone.
public enum RelayPresence: String, Sendable, CaseIterable {
    case macOnline = "mac-online"
    case macOffline = "mac-offline"
    case phoneOnline = "phone-online"
    case phoneOffline = "phone-offline"
}
