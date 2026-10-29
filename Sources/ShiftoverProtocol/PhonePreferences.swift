import Foundation

// MARK: - Phone preferences
//
// What one paired phone asks of its Mac, kept on the Mac per phone because the
// Mac is what acts on them: which agent events it pushes to that phone, and
// when it shows that phone the agents Live Activity. Read and written through
// `RPCMethod.phonePreferences`, scoped to the authenticated phone — like the
// notification mode (`PhoneNotificationMode`), a phone only ever changes its
// own delivery.
//
// Both fields decode leniently: a kind or mode added by a newer build must not
// make an older one drop the whole record and fall back to defaults.

/// When the Mac shows a phone the agents Live Activity.
public enum LiveActivityMode: String, Codable, Sendable, CaseIterable {
    /// From the moment an agent starts working until none is (the default).
    case whileWorking
    /// Only while an agent waits on the user or has stopped with an error.
    case whenNeeded
    /// Never.
    case never

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveActivityMode(rawValue: raw) ?? .whileWorking
    }
}

public struct PhonePreferencesDTO: Codable, Sendable, Equatable {
    /// Which agent events notify this phone. `nil` follows the Mac's own
    /// notification settings, whatever they become.
    public var notificationKinds: [PushContent.Kind]?
    public var liveActivity: LiveActivityMode

    public init(notificationKinds: [PushContent.Kind]? = nil, liveActivity: LiveActivityMode = .whileWorking) {
        self.notificationKinds = notificationKinds
        self.liveActivity = liveActivity
    }

    private enum CodingKeys: String, CodingKey { case notificationKinds, liveActivity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationKinds = try container.decodeIfPresent([String].self, forKey: .notificationKinds)?
            .compactMap(PushContent.Kind.init(rawValue:))
        liveActivity = try container.decodeIfPresent(LiveActivityMode.self, forKey: .liveActivity) ?? .whileWorking
    }

    /// Whether this phone wants `kind`, given the Mac's own kinds.
    public func wants(_ kind: PushContent.Kind, macKinds: Set<PushContent.Kind>) -> Bool {
        notificationKinds.map { $0.contains(kind) } ?? macKinds.contains(kind)
    }

    /// Whether the Live Activity should be showing on this phone, given what
    /// the Mac's agents are doing.
    public func showsLiveActivity(_ content: AgentsActivityContent) -> Bool {
        guard content.isActive else { return false }
        switch liveActivity {
        case .whileWorking: return true
        case .whenNeeded: return content.agents.contains { $0.status.needsAttention }
        case .never: return false
        }
    }
}

/// A phone's preferences as the Mac holds them, with the Mac's own
/// notification kinds — what a phone that follows the Mac gets.
public struct PhonePreferencesStateDTO: Codable, Sendable, Equatable {
    public let preferences: PhonePreferencesDTO
    public let macNotificationKinds: [PushContent.Kind]

    public init(preferences: PhonePreferencesDTO, macNotificationKinds: [PushContent.Kind]) {
        self.preferences = preferences
        self.macNotificationKinds = macNotificationKinds
    }

    private enum CodingKeys: String, CodingKey { case preferences, macNotificationKinds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try container.decode(PhonePreferencesDTO.self, forKey: .preferences)
        macNotificationKinds = try container.decode([String].self, forKey: .macNotificationKinds)
            .compactMap(PushContent.Kind.init(rawValue:))
    }

    /// The kinds that reach this phone now.
    public var effectiveNotificationKinds: Set<PushContent.Kind> {
        Set(preferences.notificationKinds ?? macNotificationKinds)
    }
}
