import Foundation

/// Per-phone delivery preference. This never changes the Mac's own banners.
public enum PhoneNotificationMode: String, Codable, Sendable, CaseIterable {
    case automatic, always, muted
}

public struct NotificationPresenceDTO: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case bluetooth, macActivity, locked
    }
    public let mode: PhoneNotificationMode
    public let isAway: Bool
    public let source: Source
    /// Random per-run service, obtained only over the authenticated connection.
    public let bluetoothServiceID: UUID?
    public var notificationsEnabled: Bool {
        mode == .always || (mode == .automatic && isAway)
    }
    public init(mode: PhoneNotificationMode, isAway: Bool, source: Source,
                bluetoothServiceID: UUID? = nil) {
        self.mode = mode
        self.isAway = isAway
        self.source = source
        self.bluetoothServiceID = bluetoothServiceID
    }
}
