import CryptoKit
import Foundation

// Collaborators (PLAN_52 Phase 2): two Macs paired once, each serving its own
// terminals to the other while both are live in the same repository.

/// Which repository a project is, comparable across Macs and clones: the
/// normalised `origin` URL (hashed) and the root commits.
public struct RepoIdentity: Codable, Sendable, Hashable {
    /// SHA-256 (hex) of `normalizedOrigin`, so SSH and HTTPS clones agree.
    public var originHash: String?
    /// `git rev-list --max-parents=0 HEAD`, at most a few.
    public var rootCommits: [String]

    public init(originHash: String?, rootCommits: [String]) {
        self.originHash = originHash
        self.rootCommits = Array(rootCommits.prefix(8))
    }

    public init(originURL: String?, rootCommits: [String]) {
        self.init(originHash: originURL.flatMap(Self.normalizedOrigin).map(Self.hash), rootCommits: rootCommits)
    }

    public var isEmpty: Bool { originHash == nil && rootCommits.isEmpty }

    /// The same remote, or a shared root commit (a fork and its upstream).
    public func matches(_ other: RepoIdentity) -> Bool {
        if let mine = originHash, mine == other.originHash { return true }
        return !Set(rootCommits).isDisjoint(with: other.rootCommits)
    }

    /// `host/owner/repo`, lowercased, from any of git's remote URL forms:
    /// `git@host:owner/repo.git`, `ssh://git@host:22/owner/repo`,
    /// `https://user@host/owner/repo/`. Nil for a local path.
    public static func normalizedOrigin(_ url: String) -> String? {
        var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, !rest.hasPrefix("/"), !rest.hasPrefix("~"), !rest.hasPrefix(".") else { return nil }
        var hasScheme = false
        if let range = rest.range(of: "://") {
            if rest[..<range.lowerBound].lowercased() == "file" { return nil }
            rest = String(rest[range.upperBound...])
            hasScheme = true
        }
        let hostEnd = rest.firstIndex(where: { $0 == "/" || (!hasScheme && $0 == ":") }) ?? rest.endIndex
        var host = String(rest[..<hostEnd])
        var path = hostEnd < rest.endIndex ? String(rest[rest.index(after: hostEnd)...]) : ""
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if hasScheme, let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            host = String(host[..<colon])
        }
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host + "/" + path).lowercased()
    }

    public static func hash(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// How a collaborator reaches this Mac: its LAN address and port, and the
/// relay route it serves for them.
public struct CollaboratorRoute: Codable, Sendable, Equatable {
    public let address: String
    public let port: UInt16
    public let relay: RelayRoute?

    public init(address: String, port: UInt16, relay: RelayRoute?) {
        self.address = address; self.port = port; self.relay = relay
    }

    public var isValid: Bool {
        !address.isEmpty && address.utf8.count <= 253 && port > 0
            && !address.contains(where: { $0.isWhitespace || "/?#@".contains($0) })
            && (relay == nil || relay?.isSharingRoute == true)
    }
}

/// Pairs this Mac with another as collaborators. Like `ShareInvitation`: one
/// use, ten minutes, the secret in the URL fragment; no project.
public struct CollaboratorInvitation: Codable, Equatable, Sendable {
    public let version: Int
    public let pairingID: String
    public let hostName: String
    public let address: String
    public let port: UInt16
    public let publicKey: Data
    public let secret: Data
    public let expiresAt: Date
    public let relay: RelayRoute?

    public init(hostName: String, address: String, port: UInt16, publicKey: Data,
                now: Date = Date(), relay: RelayRoute? = nil) {
        version = 1
        pairingID = RemotePairing.randomToken(byteCount: 16)
        self.hostName = hostName; self.address = address; self.port = port
        self.publicKey = publicKey; self.relay = relay
        secret = RemotePairing.randomBytes(32)
        expiresAt = now.addingTimeInterval(600)
    }

    public var route: CollaboratorRoute { CollaboratorRoute(address: address, port: port, relay: relay) }

    public var pairingCode: RemotePairing.Code {
        .init(pairingID: pairingID, serviceName: hostName, publicKey: publicKey,
              secret: secret, expiresAt: expiresAt)
    }

    public func url(landingPage: URL? = nil) -> URL? {
        InvitationLink.url(self, base: landingPage ?? URL(string: "shiftover://collaborate")!)
    }

    public static func parse(_ url: URL, now: Date = Date()) -> CollaboratorInvitation? {
        guard (url.scheme == "shiftover" && url.host == "collaborate") ||
                (url.scheme == "https" && url.path == "/collaborate"),
              let link: Self = InvitationLink.decode(url),
              link.version == 1, link.route.isValid, link.publicKey.count == 32, link.secret.count == 32,
              !link.pairingID.isEmpty, link.pairingID.utf8.count <= 128,
              !link.hostName.isEmpty, link.hostName.utf8.count <= 256, link.expiresAt > now else { return nil }
        return link
    }
}

/// An invitation carried in a URL fragment, which no landing page receives.
enum InvitationLink {
    static func url<T: Encodable>(_ value: T, base: URL) -> URL? {
        guard let data = try? JSONEncoder().encode(value),
              var url = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        url.fragment = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return url.url
    }

    static func decode<T: Decodable>(_ url: URL) -> T? {
        guard let fragment = url.fragment, fragment.utf8.count <= 8192 else { return nil }
        var base64 = fragment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
