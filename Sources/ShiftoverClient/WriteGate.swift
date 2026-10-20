// MARK: - WriteGate (PLAN_45 D9 — a phone that can act on the Mac asks who is holding it)
//
// A paired phone with the write grant is a remote shell with the user's full
// privileges on their Mac. An unlocked phone left on a table, or handed to a
// child to watch a video, must not be one for whoever is holding it — so every
// write (`RPCMethod.isWrite`) asks for Face ID, Touch ID or the passcode first.
//
// Once, not per tap: a successful check unlocks writes for `window`, and going
// to the background locks them again. A prompt on every keystroke of a reply
// would be a gate users turn off, which protects nothing.

import Foundation
import LocalAuthentication

@MainActor
public protocol WriteAuthorizing: AnyObject {
    /// Whether writes are unlocked right now, without prompting.
    var isUnlocked: Bool { get }
    /// Unlocks writes, prompting if needed. `false` if the user declined.
    func authorize() async -> Bool
    /// The OS has just authenticated the user for a specific action — an
    /// Allow / Deny / Reply on a notification, which requires the device
    /// unlocked. Counts as an unlock; prompting again, from the background,
    /// could not even succeed.
    func noteDeviceAuthenticated()
    /// Locks writes — the app went to the background.
    func lock()
    /// The last `authorize()` failed because this phone has no passcode, so
    /// there is no owner to check. Lets the caller say what to fix.
    var needsPasscode: Bool { get }
    /// The context the owner authenticated with, while unlocked. The Secure
    /// Enclave's owner key signs under it without asking again, which is how
    /// one Face ID both unlocks the phone's gate and proves presence to the
    /// Mac (`PresenceKeys`). `nil` after a notification unlock, which had no
    /// prompt of its own.
    var authenticationContext: LAContext? { get }
    /// Like `authorize()`, but makes sure `authenticationContext` is set, asking
    /// again if the gate was opened without a prompt (by a notification
    /// action). Without a context the owner key would show its own prompt from
    /// inside a call that blocks the main thread.
    func authorizeForPresence() async -> Bool
}

public extension WriteAuthorizing {
    var needsPasscode: Bool { false }
    var authenticationContext: LAContext? { nil }
    func authorizeForPresence() async -> Bool { await authorize() }
}

@MainActor
public final class DeviceOwnerGate: WriteAuthorizing {

    /// How long one check covers.
    public static let window: TimeInterval = 5 * 60

    /// Asks the device owner to authenticate. Injectable for tests.
    public typealias Evaluator = @MainActor (_ reason: String) async -> EvaluationResult

    public enum EvaluationResult: Equatable {
        /// Carries the evaluated context; `nil` from a test evaluator.
        case authenticated(LAContext?)
        case declined
        /// No passcode on this phone: there is nothing to check against, and
        /// such a phone is open to anyone holding it — so it may read, but
        /// never act on the Mac.
        case unavailable
    }

    private let evaluate: Evaluator
    private let now: () -> Date
    private var unlockedUntil: Date?
    public private(set) var needsPasscode = false
    public private(set) var authenticationContext: LAContext?

    public init(evaluate: Evaluator? = nil, now: @escaping () -> Date = Date.init) {
        self.evaluate = evaluate ?? DeviceOwnerGate.localAuthentication
        self.now = now
    }

    public var isUnlocked: Bool {
        guard let until = unlockedUntil else { return false }
        return until > now()
    }

    public func authorize() async -> Bool {
        if isUnlocked {
            unlockedUntil = now().addingTimeInterval(Self.window)
            return true
        }
        switch await evaluate("Confirm it's you before acting on your Mac.") {
        case .authenticated(let context):
            needsPasscode = false
            authenticationContext = context
            unlockedUntil = now().addingTimeInterval(Self.window)
            return true
        case .declined:
            needsPasscode = false
            return false
        case .unavailable:
            // Write access is a shell on the Mac with the user's privileges.
            // A phone anyone can pick up and use must not be one.
            needsPasscode = true
            return false
        }
    }

    public func authorizeForPresence() async -> Bool {
        if isUnlocked, authenticationContext == nil { lock() }
        return await authorize()
    }

    public func noteDeviceAuthenticated() {
        unlockedUntil = now().addingTimeInterval(Self.window)
    }

    public func lock() {
        unlockedUntil = nil
        authenticationContext?.invalidate()
        authenticationContext = nil
    }

    /// Face ID / Touch ID, falling back to the passcode.
    private static let localAuthentication: Evaluator = { reason in
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode is the case this exists for; any other reason the
            // owner cannot be checked (lockout, a restricted device) is a
            // refusal too, never a pass.
            return (error as? LAError)?.code == .passcodeNotSet ? .unavailable : .declined
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: reason)
                ? .authenticated(context) : .declined
        } catch {
            return .declined
        }
    }
}

/// For previews, render tests and fixtures: every write is allowed.
@MainActor
public final class OpenGate: WriteAuthorizing {
    public init() {}
    public var isUnlocked: Bool { true }
    public func authorize() async -> Bool { true }
    public func noteDeviceAuthenticated() {}
    public func lock() {}
}
