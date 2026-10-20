// MARK: - Presence keys (PLAN_45 D9 — Face ID the Mac can check)
//
// `WriteGate` asks for Face ID before a write, but that check runs on the
// phone, so on its own the Mac would be taking the phone's word for it. These
// two Secure Enclave keys let the Mac check for itself (`PresenceProof` in
// shiftover-protocol):
//
//   • **owner** signs only after Face ID, Touch ID or the passcode. The gate's
//     own authentication is reused, so proving presence to the Mac costs no
//     second prompt.
//   • **unlocked** signs without a prompt while the phone is unlocked. The Mac
//     accepts it only for a lock-screen answer, bound to that answer.
//
// The keys never leave the Secure Enclave. What the keychain holds is the
// enclave's wrapped blob, which only this phone's enclave can use, and only
// under the conditions set when the key was made. The owner key needs a
// passcode to exist at all, so a phone without one has no keys and stays
// read-only on the Mac too.

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import ShiftoverProtocol

@MainActor
public protocol PresenceSigning: AnyObject {
    /// The public halves, creating the keys on first use. `nil` when this
    /// phone cannot hold them: no passcode, no Secure Enclave, or locked.
    func presenceKeys() -> PresenceKeys?
    /// Signs `message` (ECDSA P-256, DER). For `.owner`, `context` is the one
    /// the owner just authenticated with; without it the Secure Enclave would
    /// show its own prompt.
    func sign(_ message: Data, level: PresenceLevel, context: LAContext?) throws -> Data
}

public enum PresenceSigningError: Error, Equatable {
    /// This phone has no usable key for that level.
    case noKey
}

/// The real thing: keys in the Secure Enclave.
@MainActor
public final class SecureEnclavePresence: PresenceSigning {

    #if os(macOS)
    private let service = "app.shiftover.mac.presence"
    #else
    private let service = "app.shiftover.go.presence"
    #endif
    /// The app's own keychain group, not the one shared with the notification
    /// extension: nothing but the app signs.
    private let accessGroup = "746889X99S.app.shiftover.go"

    nonisolated public init() {}

    public func presenceKeys() -> PresenceKeys? {
        guard SecureEnclave.isAvailable,
              let owner = key(.owner, create: true),
              let unlocked = key(.unlocked, create: true) else { return nil }
        return PresenceKeys(owner: owner.publicKey.x963Representation,
                            unlocked: unlocked.publicKey.x963Representation)
    }

    public func sign(_ message: Data, level: PresenceLevel, context: LAContext?) throws -> Data {
        guard let key = key(level, context: context, create: false) else {
            throw PresenceSigningError.noKey
        }
        return try key.signature(for: message).derRepresentation
    }

    // MARK: - Storage

    private func key(_ level: PresenceLevel, context: LAContext? = nil,
                     create: Bool) -> SecureEnclave.P256.Signing.PrivateKey? {
        switch read(level) {
        case .found(let blob):
            if let key = try? SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob, authenticationContext: context) {
                return key
            }
            // The enclave no longer accepts the blob: the passcode was removed
            // since, which destroys keys that require one. A new key will not
            // match what the Mac has, so writes need pairing again; reads go on.
            delete(level)
        case .unavailable:
            // Locked: the item exists but cannot be read now. Never treat that
            // as missing, or a background reconnect would replace the keys.
            return nil
        case .missing:
            break
        }
        guard create else { return nil }
        guard let access = SecAccessControlCreateWithFlags(
            nil, Self.protection(level), Self.flags(level), nil),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(
                  compactRepresentable: false, accessControl: access)
        else { return nil }
        guard write(key.dataRepresentation, level: level) else { return nil }
        return key
    }

    private static func protection(_ level: PresenceLevel) -> CFString {
        switch level {
        // Destroyed if the passcode is removed: without one, anyone holding the
        // phone could pass as its owner.
        case .owner:
            #if os(macOS)
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #else
            return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            #endif
        case .unlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }

    private static func flags(_ level: PresenceLevel) -> SecAccessControlCreateFlags {
        switch level {
        // Face ID, Touch ID or the passcode — the same check as `WriteGate`.
        case .owner: return [.privateKeyUsage, .userPresence]
        case .unlocked: return [.privateKeyUsage]
        }
    }

    private enum ReadResult { case found(Data), missing, unavailable }

    private func query(_ level: PresenceLevel) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: level.rawValue]
        #if os(iOS)
        result[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return result
    }

    private func read(_ level: PresenceLevel) -> ReadResult {
        var q = query(level)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess: return (result as? Data).map(ReadResult.found) ?? .missing
        case errSecItemNotFound: return .missing
        default: return .unavailable
        }
    }

    private func write(_ data: Data, level: PresenceLevel) -> Bool {
        delete(level)
        var q = query(level)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = Self.protection(level)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private func delete(_ level: PresenceLevel) {
        SecItemDelete(query(level) as CFDictionary)
    }
}
