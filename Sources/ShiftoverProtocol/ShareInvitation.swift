import CryptoKit
import Foundation

/// Share secrets travel in URL fragments, never requests to the landing page.
public struct ShareInvitation: Codable, Equatable, Sendable {
    public let version: Int
    public let pairingID: String
    public let projectID: UUID
    public let projectName: String
    public let hostName: String
    public let address: String
    public let port: UInt16
    public let publicKey: Data
    public let secret: Data
    public let expiresAt: Date
    public let relay: RelayRoute?

    public init(projectID: UUID, projectName: String, hostName: String, address: String,
                port: UInt16, publicKey: Data, now: Date = Date(), relay: RelayRoute? = nil) {
        version = 1
        self.relay = relay
        pairingID = RemotePairing.randomToken(byteCount: 16)
        self.projectID = projectID; self.projectName = projectName; self.hostName = hostName
        self.address = address; self.port = port; self.publicKey = publicKey
        secret = RemotePairing.randomBytes(32)
        expiresAt = now.addingTimeInterval(600)
    }

    public var pairingCode: RemotePairing.Code {
        .init(pairingID: pairingID, serviceName: hostName, publicKey: publicKey,
              secret: secret, expiresAt: expiresAt)
    }

    public func url(landingPage: URL? = nil) -> URL? {
        InvitationLink.url(self, base: landingPage ?? URL(string: "shiftover://join")!)
    }

    public static func parse(_ url: URL, now: Date = Date()) -> ShareInvitation? {
        guard (url.scheme == "shiftover" && url.host == "join") ||
                (url.scheme == "https" && url.path == "/join"),
              let link: Self = InvitationLink.decode(url),
              link.version == 1, (link.relay == nil || link.relay?.isSharingRoute == true), link.publicKey.count == 32, link.secret.count == 32,
              !link.pairingID.isEmpty, link.pairingID.utf8.count <= 128,
              !link.address.isEmpty, link.address.utf8.count <= 253, link.port > 0,
              !link.address.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
              link.projectName.utf8.count <= 256, !link.hostName.isEmpty,
              link.hostName.utf8.count <= 256, link.expiresAt > now else { return nil }
        return link
    }

    public static func confirmationCode(handshakeHash: Data) -> String {
        let digest = SHA256.hash(data: Data("shiftover-share-confirmation-v1".utf8) + handshakeHash)
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }
}
