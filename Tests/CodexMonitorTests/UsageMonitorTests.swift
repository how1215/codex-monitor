import Foundation
import Testing
@testable import CodexMonitor

@MainActor
struct UsageMonitorTests {
    @Test func consumeResetUsesAvailableCreditAndRefreshes() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        monitor.start()
        await waitUntil { monitor.phase == .ready }

        await monitor.consumeReset()

        #expect(service.consumedCreditID == "reset-1")
        #expect(!(service.idempotencyKey?.isEmpty ?? true))
        #expect(monitor.message == "用量已重置。")
        #expect(service.usageFetchCount >= 2)
        monitor.stop()
    }

    @Test func doesNotConsumeWithoutAvailableReset() async {
        let service = FakeCodexService(availableResetCount: 0)
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        monitor.start()
        await waitUntil { monitor.phase == .ready }

        await monitor.consumeReset()

        #expect(service.idempotencyKey == nil)
        monitor.stop()
    }

    @Test func resetRetryReusesPersistedIdempotencyKey() async {
        let service = FakeCodexService(resetFailuresBeforeSuccess: 1)
        let store = makeResetStore()
        let monitor = UsageMonitor(service: service, resetAttemptStore: store)
        await waitUntil { monitor.phase == .ready }

        await monitor.consumeReset()
        let firstKey = service.idempotencyKeys.first
        #expect(store.load()?.idempotencyKey == firstKey)

        await monitor.consumeReset()
        #expect(service.idempotencyKeys.count == 2)
        #expect(service.idempotencyKeys[0] == service.idempotencyKeys[1])
        #expect(store.load() == nil)
        monitor.stop()
    }

    @Test func reconnectBackoffIsBounded() {
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 1, jitter: 0) == 2)
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 2, jitter: 0) == 4)
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 20, jitter: 0) == 30)
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 20, jitter: 1) == 30.5)
    }

    @Test func authenticationURLAllowlistRejectsUnsafeURLs() {
        #expect(CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://chatgpt.com/auth")!))
        #expect(CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://auth.openai.com/login")!))
        #expect(!CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "http://chatgpt.com/auth")!))
        #expect(!CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://chatgpt.com.example.test/auth")!))
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<50 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for state")
    }

    private func makeResetStore() -> ResetAttemptStore {
        let suiteName = "CodexMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ResetAttemptStore(defaults: defaults)
    }
}

private final class FakeCodexService: CodexService {
    var onUsageChanged: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var consumedCreditID: String?
    var idempotencyKey: String?
    var idempotencyKeys: [String] = []
    var usageFetchCount = 0

    private let availableResetCount: Int
    private var resetFailuresBeforeSuccess: Int

    init(availableResetCount: Int = 1, resetFailuresBeforeSuccess: Int = 0) {
        self.availableResetCount = availableResetCount
        self.resetFailuresBeforeSuccess = resetFailuresBeforeSuccess
    }

    func events() async -> AsyncStream<CodexServiceEvent> {
        AsyncStream { _ in }
    }

    func start() async throws {}
    func stop() async {}

    func fetchAccount() async throws -> AccountStatus? {
        AccountStatus(authType: "chatgpt", email: nil, planType: "plus")
    }

    func fetchUsage() async throws -> UsageSnapshot {
        usageFetchCount += 1
        let resets = availableResetCount > 0 ? [
            ResetCredit(
                id: "reset-1",
                resetType: "codexRateLimits",
                status: "available",
                grantedAt: nil,
                expiresAt: nil,
                title: nil,
                description: nil
            )
        ] : []
        return UsageSnapshot(
            windows: [],
            resetCredits: resets,
            availableResetCount: availableResetCount,
            credits: nil,
            fetchedAt: Date()
        )
    }

    func consumeReset(creditID: String?, idempotencyKey: String) async throws -> ResetOutcome {
        consumedCreditID = creditID
        self.idempotencyKey = idempotencyKey
        idempotencyKeys.append(idempotencyKey)
        if resetFailuresBeforeSuccess > 0 {
            resetFailuresBeforeSuccess -= 1
            throw CodexMonitorError.disconnected
        }
        return .reset
    }

    func beginChatGPTLogin() async throws -> URL {
        URL(string: "https://chatgpt.com")!
    }
}
