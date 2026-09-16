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

enum ResetStoreError: LocalizedError {
    case corrupted
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .corrupted: "The saved reset recovery record is unreadable. No new reset will be sent."
        case .persistenceFailed: "Could not persist reset recovery. No reset request was sent."
        }
    }
}

@MainActor
final class ResetAttemptStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "pendingResetAttempt") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> PendingResetAttempt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let attempt = try? JSONDecoder().decode(PendingResetAttempt.self, from: data),
              !attempt.idempotencyKey.isEmpty else { throw ResetStoreError.corrupted }
        return attempt
    }

    func save(_ attempt: PendingResetAttempt) throws {
        let data = try JSONEncoder().encode(attempt)
        defaults.set(data, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == data else {
            throw ResetStoreError.persistenceFailed
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
