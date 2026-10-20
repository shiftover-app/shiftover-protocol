import Foundation

/// A foreground-only, single-flight health check and recovery loop. A failed
/// read can reconnect; writes are never queued or replayed by this owner.
@MainActor
public final class ConnectionRecovery {
    public enum Outcome { case healthy, retry, stop }
    private let check: () async -> Outcome
    private let healthyInterval: Duration
    private let retryDelay: (Int) -> Duration
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    public private(set) var running = false

    public init(healthyInterval: Duration = .seconds(15),
         retryDelay: @escaping (Int) -> Duration = { .seconds(min(30, pow(2, Double(min($0, 5))))) },
         check: @escaping () async -> Outcome) {
        self.healthyInterval = healthyInterval
        self.retryDelay = retryDelay
        self.check = check
    }

    public func start(immediately: Bool = false) {
        guard !running else { return }
        running = true
        failures = 0
        schedule(after: immediately ? .zero : healthyInterval)
    }

    public func checkSoon() {
        guard running, work == nil else { return }
        schedule(after: .milliseconds(250))
    }

    public func stop() {
        running = false
        generation += 1
        timer?.cancel(); timer = nil
        work?.cancel(); work = nil
    }

    private func schedule(after delay: Duration) {
        timer?.cancel()
        let mine = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.running, mine == self.generation else { return }
            self.timer = nil
            self.run(generation: mine)
        }
    }

    private func run(generation mine: Int) {
        guard work == nil else { return }
        work = Task { [weak self, check] in
            let outcome = await check()
            guard let self, self.running, mine == self.generation, !Task.isCancelled else { return }
            self.work = nil
            switch outcome {
            case .healthy:
                self.failures = 0
                self.schedule(after: self.healthyInterval)
            case .retry:
                let delay = self.retryDelay(self.failures)
                self.failures += 1
                self.schedule(after: delay)
            case .stop:
                self.stop()
            }
        }
    }

    deinit { timer?.cancel(); work?.cancel() }
}
