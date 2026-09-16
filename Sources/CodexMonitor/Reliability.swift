import Foundation

struct ReconnectPolicy {
    static func delaySeconds(forAttempt attempt: Int, jitter: Double = Double.random(in: 0...0.5)) -> Double {
        let exponent = Double(max(1, attempt))
        return min(30, pow(2, exponent)) + min(max(jitter, 0), 0.5)
    }
}

struct PendingResetAttempt: Codable, Equatable {
    let idempotencyKey: String
    let creditID: String?
    let startedAt: Date
}

@MainActor
final class ResetAttemptStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "pendingResetAttempt") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PendingResetAttempt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingResetAttempt.self, from: data)
    }

    func save(_ attempt: PendingResetAttempt) throws {
        defaults.set(try JSONEncoder().encode(attempt), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
