// MARK: - RemotePairing (PLAN_45 D14 — Mac-authoritative, offline pairing)
//
// Pairing establishes mutual trust between one Mac and one phone, in person,
// with no service involvement. The Mac shows a QR; the phone scans it; both end
// up holding the other's long-term X25519 public key.
//
// Shared rather than app-local because **both ends run this code**: the Mac
// mints and renders the code, the phone parses it, and both compute the same
// authentication tag.
//
// ── Why the Mac is authoritative ────────────────────────────────────────
//
// Pairing must work with the internet down (D14), so nothing here may depend on
// Shiftover Cloud. The consequence is the good part: when the relay is later
// introduced, it routes between two endpoints that ALREADY trust each other. It
// never witnesses pairing, never holds a pairing secret, and therefore
// authenticates only for **billing** — never for **trust**.
//
// ── What the QR's two secrets each defend ───────────────────────────────
//
// The QR travels over a channel an attacker cannot reach — a screen, in the
// room — and carries two things:
//
//   • The Mac's public key. The phone runs Noise IK against it, so nobody
//     without the Mac's private key can answer — an impostor Mac cannot even
//     read message 1. That is the defence against a man in the middle.
//   • A one-time secret. The Mac would otherwise accept *any* phone that can
//     run a handshake; the secret is what limits pairing to the phone that
//     actually saw the screen. The phone proves it with an HMAC over the
//     handshake hash (`pairingProof`), so the proof is bound to one handshake
//     and cannot be lifted into another.

import CryptoKit
import Foundation

public enum RemotePairing {

    /// How long a displayed code stays valid. Short enough that a QR left on a
    /// screen — or in a screenshot, or over someone's shoulder on a video call —
    /// stops being useful quickly; long enough to scan without hurrying.
    public static let codeLifetime: TimeInterval = 60

    /// Bytes of one-time secret. 32 is well past what a 60-second window needs,
    /// and the code is scanned rather than typed, so being generous costs
    /// nothing.
    public static let secretByteCount = 32

    // MARK: - The QR payload

    /// What the Mac renders as a QR and the phone scans.
    ///
    /// Deliberately NOT an opaque `Codable` blob: this is read by a camera, so
    /// its size directly determines how dense the QR is and how reliably it
    /// scans. A compact URL keeps it in low error-correction territory, and
    /// reuses the project's existing `shiftover://` scheme vocabulary.
    public struct Code: Equatable, Sendable {
        /// Stable identifier for this pairing, and the relay's DO name later.
        public let pairingID: String
        /// Bonjour service name — the phone browses rather than dialing an IP,
        /// so a DHCP lease change does not break an existing pairing.
        public let serviceName: String
        /// The Mac's long-term X25519 public key.
        public let publicKey: Data
        /// One-time secret authenticating the exchange. Burned after use.
        public let secret: Data
        public let expiresAt: Date

        public init(pairingID: String, serviceName: String, publicKey: Data,
                    secret: Data, expiresAt: Date) {
            self.pairingID = pairingID
            self.serviceName = serviceName
            self.publicKey = publicKey
            self.secret = secret
            self.expiresAt = expiresAt
        }

        public var isExpired: Bool { Date() >= expiresAt }
    }

    /// Mints a fresh code.
    public static func makeCode(
        serviceName: String,
        publicKey: Data,
        now: Date = Date()
    ) -> Code {
        Code(pairingID: randomToken(byteCount: 16),
             serviceName: serviceName,
             publicKey: publicKey,
             secret: randomBytes(secretByteCount),
             expiresAt: now.addingTimeInterval(codeLifetime))
    }

    /// Cryptographically secure random bytes — never `Int.random`, which is
    /// unsuitable for anything load-bearing.
    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes)
    }

    public static func randomToken(byteCount: Int) -> String {
        base64url(randomBytes(byteCount))
    }

    // MARK: - URL encoding

    /// Renders a code as the URL the QR encodes.
    public static func url(for code: Code) -> URL? {
        var components = URLComponents()
        components.scheme = "shiftover"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: code.pairingID),
            URLQueryItem(name: "n", value: code.serviceName),
            URLQueryItem(name: "k", value: base64url(code.publicKey)),
            URLQueryItem(name: "s", value: base64url(code.secret))
        ]
        return components.url
    }

    /// Parses a scanned URL.
    ///
    /// The scanning side supplies the expiry from its own clock rather than
    /// trusting one in the payload — an expiry an attacker can edit is not an
    /// expiry. The Mac enforces the real window at redemption; this only lets
    /// the phone fail fast with a clear message.
    public static func parse(_ url: URL, now: Date = Date()) -> Code? {
        guard url.scheme == "shiftover", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("v") == "1",
              let id = value("id"), !id.isEmpty,
              let name = value("n"), !name.isEmpty,
              let keyData = value("k").flatMap(decodeBase64url), keyData.count == 32,
              let secret = value("s").flatMap(decodeBase64url),
              secret.count == secretByteCount
        else { return nil }

        return Code(pairingID: id, serviceName: name, publicKey: keyData,
                    secret: secret, expiresAt: now.addingTimeInterval(codeLifetime))
    }

    // MARK: - Proving the code was seen

    /// Proves possession of the code's one-time secret, bound to one handshake.
    ///
    /// Computed over the Noise handshake hash as it stands just before the
    /// phone's payload is sealed. That hash covers the prologue, the Mac's key,
    /// the phone's ephemeral key and its (encrypted) static key, so the proof is
    /// unique to this handshake: replaying it into another — even between the
    /// same two devices — does not verify.
    ///
    /// The pairing id is included so a proof for one code cannot be presented
    /// against another.
    public static func pairingProof(secret: Data, pairingID: String, handshakeHash: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: proofMessage(pairingID, handshakeHash),
            using: SymmetricKey(data: secret)))
    }

    /// Verifies a proof in **constant time**.
    ///
    /// `isValidAuthenticationCode` rather than `==` on `Data`: a byte-by-byte
    /// comparison leaks, through timing, how much of the proof was correct,
    /// which turns forgery into a per-byte search.
    public static func verifyPairingProof(_ proof: Data, secret: Data, pairingID: String,
                                          handshakeHash: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: proofMessage(pairingID, handshakeHash),
            using: SymmetricKey(data: secret))
    }

    private static func proofMessage(_ pairingID: String, _ handshakeHash: Data) -> Data {
        // The hash is fixed-length and last, so the variable-length id before it
        // cannot be shifted to make two different inputs collide.
        var message = Data("shiftover-pair/v2".utf8)
        message.append(Data(pairingID.utf8))
        message.append(handshakeHash)
        return message
    }

    // MARK: - base64url

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
