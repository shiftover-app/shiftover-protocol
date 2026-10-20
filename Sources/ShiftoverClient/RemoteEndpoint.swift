// MARK: - RemoteEndpoint
//
// Where a resolved Mac lives, and how that becomes a URL a WebSocket can dial.
//
// ── Why this is its own type rather than a `(String, UInt16)` tuple ──────
//
// Because "the host string" is not a plain host string, and treating it as one
// is a real bug that cost a working pairing. Bonjour on a LAN resolves to an
// IPv6 **link-local** address far more often than to IPv4 — measured on a
// normal home network, the very first resolve returned
// `fe80::5ce9:1eff:fe5b:e06b%bridge107`. Two things about that address are
// load-bearing and both are easy to lose:
//
//   • The `%zone` suffix is not decoration. A link-local address is only
//     meaningful *on a specific interface* — `fe80::1` alone does not identify
//     a machine, and the kernel has no way to guess which interface to send
//     out of. Strip the zone and the address becomes unroutable.
//   • An IPv6 literal must be **bracketed** inside a URL authority, and the
//     zone's `%` must itself be percent-encoded to `%25` (RFC 6874) — bare, the
//     `%` reads as the start of a percent-escape and the parse fails.
//
// Measured against a live Shiftover listener, exactly one of these connects:
//
//     ws://192.168.0.36:56658                       → opens
//     ws://fe80::c93:8c55:bf6d:c86d:56658           → URL(string:) is NIL
//     ws://[fe80::c93:8c55:bf6d:c86d]:56658         → "connection appears offline"
//     ws://[fe80::c93:8c55:bf6d:c86d%25en0]:56658   → opens
//
// A `nil` URL is the worst of those outcomes because it fails *before* any
// networking happens, so it does not look like a network problem at all.

import Foundation

/// A resolved Mac: an address to dial, and the port it is listening on.
public struct RemoteEndpoint: Equatable, Sendable {

    /// The address as the OS resolved it — **including any IPv6 zone**
    /// (`fe80::1%en0`). Kept in that form rather than pre-formatted so the
    /// value stays a plain address that can be logged, compared or handed to
    /// Network.framework; URL escaping happens at the one place a URL is built.
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// The `ws://` URL for this endpoint, or `nil` if it cannot be expressed as
    /// one.
    ///
    /// `URLComponents` is deliberately avoided here: it re-encodes the `%` in a
    /// zone id and rejects the bracketed literal, so the string is assembled
    /// directly and handed to `URL(string:)`, which is also what actually has
    /// to accept it.
    public func webSocketURL() -> URL? {
        // `URL(string: "ws://:56658")` parses happily into a hostless URL, so
        // the empty case has to be rejected here — otherwise a failed resolve
        // turns into a URLSession error much further downstream, where it reads
        // as a network fault rather than as "we never found the Mac".
        let authority = Self.urlAuthorityHost(host)
        guard !authority.isEmpty else { return nil }
        return URL(string: "ws://\(authority):\(port)")
    }

    /// Formats an address for the host slot of a URL authority.
    ///
    /// Pure and separately testable, because every interesting case here is a
    /// string-shape case: IPv4 passes through, a hostname passes through, and
    /// only an IPv6 literal needs brackets and a `%25`-escaped zone.
    public static func urlAuthorityHost(_ host: String) -> String {
        // Tolerate an already-bracketed literal so this is idempotent — a
        // double bracket would be silently unparseable.
        var bare = host
        if bare.hasPrefix("["), bare.hasSuffix("]") {
            bare = String(bare.dropFirst().dropLast())
        }

        // A colon can only appear in an IPv6 literal here; hostnames and IPv4
        // addresses never contain one, and the port is not part of this string.
        guard bare.contains(":") else { return bare }

        // Escape the zone separator only. Doing it on the whole string would be
        // wrong for any `%` that is already an escape.
        let escaped = bare.replacingOccurrences(of: "%25", with: "%")
            .replacingOccurrences(of: "%", with: "%25")
        return "[\(escaped)]"
    }
}
