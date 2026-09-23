import Foundation
import Testing
@testable import CodexMonitor

@MainActor
struct UsageMonitorTests {
    @Test func consumeResetUsesAvailableCreditAndRefreshes() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        await monitor.consumeReset()
        #expect(service.consumedCreditID == "reset-1")
        #expect(!(service.idempotencyKeys.first?.isEmpty ?? true))
        #expect(monitor.message == "Usage was reset.")
        #expect(service.usageFetchCount >= 2)
        await monitor.stop()
    }

    @Test func doesNotConsumeWithoutAvailableReset() async {
        let service = FakeCodexService(availableResetCount: 0)
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        await monitor.consumeReset()
        #expect(service.idempotencyKeys.isEmpty)
        await monitor.stop()
    }

    @Test func resetRetryReusesPersistedKey() async throws {
        let service = FakeCodexService(resetFailuresBeforeSuccess: 1)
        let store = makeResetStore()
        let monitor = UsageMonitor(service: service, resetAttemptStore: store)
        await waitUntil { monitor.phase == .ready }
        await monitor.consumeReset()
        #expect(try store.load()?.idempotencyKey == service.idempotencyKeys.first)
        await monitor.consumeReset()
        #expect(service.idempotencyKeys.count == 2)
        #expect(service.idempotencyKeys[0] == service.idempotencyKeys[1])
        #expect(try store.load() == nil)
        await monitor.stop()
    }

    @Test func timedOutResetReusesKeyAfterAppRestart() async throws {
        let service = FakeCodexService(resetFailuresBeforeSuccess: 1, resetFailure: .requestTimedOut("account/rateLimitResetCredit/consume"))
        let store = makeResetStore()
        let firstMonitor = UsageMonitor(service: service, resetAttemptStore: store)
        await waitUntil { firstMonitor.phase == .ready }
        await firstMonitor.consumeReset()
        let originalKey = try #require(store.load()?.idempotencyKey)
        await firstMonitor.stop()

        let secondMonitor = UsageMonitor(service: service, resetAttemptStore: store)
        await waitUntil { secondMonitor.phase == .ready }
        #expect(secondMonitor.hasPendingResetAttempt)
        await secondMonitor.consumeReset()
        #expect(service.idempotencyKeys == [originalKey, originalKey])
        #expect(try store.load() == nil)
        await secondMonitor.stop()
    }

    @Test func corruptRecoveryBlocksReset() async {
        let suite = "CodexMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("invalid".utf8), forKey: "pendingResetAttempt")
        let monitor = UsageMonitor(service: FakeCodexService(), resetAttemptStore: ResetAttemptStore(defaults: defaults))
        await waitUntil { monitor.phase == .ready }
        #expect(monitor.resetRecoveryBlocked)
        await monitor.consumeReset()
        #expect(monitor.resetRecoveryBlocked)
        monitor.discardResetRecovery()
        #expect(!monitor.resetRecoveryBlocked)
        #expect(defaults.data(forKey: "pendingResetAttempt") == nil)
        await monitor.stop()
    }

    @Test func unsupportedAuthentication() async {
        let monitor = UsageMonitor(service: FakeCodexService(authType: "apiKey"), resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .unsupportedAuth }
        #expect(monitor.usage == nil)
        await monitor.stop()
    }

    @Test func deviceCodeLogin() async {
        let monitor = UsageMonitor(service: FakeCodexService(authType: "apiKey"), resetAttemptStore: makeResetStore())
        await monitor.signInWithDeviceCode()
        #expect(monitor.deviceCodeLogin?.userCode == "ABCD-1234")
        await monitor.stop()
    }

    @Test func reconnectBackoffIsBounded() {
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 1, jitter: 0) == 2)
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 2, jitter: 0) == 4)
        #expect(ReconnectPolicy.delaySeconds(forAttempt: 20, jitter: 0) == 30)
    }

    @Test func fiveHourSummaryUsesMostConstrainedWindowAndExactThresholds() {
        let now = Date()
        let windows = [
            RateLimitWindow(id: "short", limitID: "codex", limitName: nil, kind: "primary", usedPercent: 95, windowDurationMinutes: 60, resetsAt: now),
            RateLimitWindow(id: "five-a", limitID: "codex", limitName: nil, kind: "primary", usedPercent: 49.9, windowDurationMinutes: 300, resetsAt: now),
            RateLimitWindow(id: "five-b", limitID: "other", limitName: nil, kind: "primary", usedPercent: 80, windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(600)),
            RateLimitWindow(id: "five-c", limitID: "third", limitName: nil, kind: "primary", usedPercent: 80, windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(300))
        ]
        let snapshot = UsageSnapshot(windows: windows, resetCredits: [], availableResetCount: 0, credits: nil, fetchedAt: now)
        #expect(snapshot.fiveHourWindow?.id == "five-c")
        #expect(snapshot.fiveHourWindow?.usedPercent == 80)
        #expect(snapshot.fiveHourRemainingPercent == 20)
        #expect(snapshot.fiveHourWindow?.resetsAt == now.addingTimeInterval(300))
        let noFiveHour = UsageSnapshot(windows: [windows[0]], resetCredits: [], availableResetCount: 0, credits: nil, fetchedAt: now)
        #expect(noFiveHour.fiveHourWindow == nil)
        #expect(noFiveHour.fiveHourRemainingPercent == nil)
        #expect(MenuBarUsageLevel(usedPercent: nil) == .unavailable)
        #expect(MenuBarUsageLevel(usedPercent: 49.9) == .normal)
        #expect(MenuBarUsageLevel(usedPercent: 50) == .warning)
        #expect(MenuBarUsageLevel(usedPercent: 79.9) == .warning)
        #expect(MenuBarUsageLevel(usedPercent: 80) == .critical)
    }

    @Test func openingPanelRefreshesOnlyWhenUsageIsOlderThanOneMinute() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        let fetchedAt = monitor.usage!.fetchedAt
        let originalUsageReads = service.usageFetchCount
        let originalAccountReads = service.accountFetchCount

        await monitor.refreshIfNeededOnOpen(now: fetchedAt.addingTimeInterval(60))
        #expect(service.usageFetchCount == originalUsageReads)
        await monitor.refreshIfNeededOnOpen(now: fetchedAt.addingTimeInterval(61))
        #expect(service.usageFetchCount == originalUsageReads + 1)
        #expect(service.accountFetchCount == originalAccountReads)
        await monitor.stop()
    }

    @Test func failedPanelOpenRefreshIsThrottled() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        let firstOpen = monitor.usage!.fetchedAt.addingTimeInterval(61)
        service.usageFailure = .disconnected

        await monitor.refreshIfNeededOnOpen(now: firstOpen)
        let readsAfterFailure = service.usageFetchCount
        #expect(monitor.phase == .stale)
        await monitor.refreshIfNeededOnOpen(now: firstOpen.addingTimeInterval(30))
        #expect(service.usageFetchCount == readsAfterFailure)
        await monitor.refreshIfNeededOnOpen(now: firstOpen.addingTimeInterval(61))
        #expect(service.usageFetchCount == readsAfterFailure + 1)
        await monitor.stop()
    }

    @Test func fallbackPollingRefreshesAccountAndUsage() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore(), pollingInterval: .milliseconds(50))
        await waitUntil { monitor.phase == .ready }
        let accountReads = service.accountFetchCount
        let usageReads = service.usageFetchCount
        await waitUntil { service.accountFetchCount > accountReads && service.usageFetchCount > usageReads }
        #expect(service.accountFetchCount > accountReads)
        #expect(service.usageFetchCount > usageReads)
        await monitor.stop()
    }

    @Test func energySavingModeStopsAutomaticReadsAndUsesManualRefresh() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore(), pollingInterval: .milliseconds(50))
        await waitUntil { monitor.phase == .ready }
        await monitor.setEnergySavingMode(true)
        let accountReads = service.accountFetchCount
        let usageReads = service.usageFetchCount
        #expect(!service.isRunning)

        service.emit(.rateLimitsChanged)
        try? await Task.sleep(for: .milliseconds(350))
        await monitor.refreshIfNeededOnOpen(now: Date().addingTimeInterval(120))
        #expect(service.accountFetchCount == accountReads)
        #expect(service.usageFetchCount == usageReads)

        await monitor.refresh()
        #expect(service.accountFetchCount == accountReads + 1)
        #expect(service.usageFetchCount == usageReads + 1)
        #expect(!service.isRunning)

        await monitor.setEnergySavingMode(false)
        await waitUntil { service.accountFetchCount > accountReads + 1 }
        #expect(service.isRunning)
        await monitor.stop()
    }

    @Test func energySavingModeKeepsDeviceLoginAliveUntilCompletion() async {
        let service = FakeCodexService(authType: "apiKey")
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .unsupportedAuth }
        await monitor.setEnergySavingMode(true)
        await monitor.signInWithDeviceCode()
        #expect(monitor.isSigningIn)
        #expect(service.isRunning)
        service.authType = "chatgpt"
        service.emit(.loginCompleted(loginID: "login-1", success: true, error: nil))
        await waitUntil { !monitor.isSigningIn && monitor.phase == .ready }
        #expect(!service.isRunning)
        await monitor.stop()
    }

    @Test func energySavingModeCancelsSignInAndStopsServer() async {
        let service = FakeCodexService(authType: "apiKey")
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .unsupportedAuth }
        await monitor.setEnergySavingMode(true)
        await monitor.signInWithDeviceCode()
        #expect(service.isRunning)
        await monitor.cancelLogin()
        #expect(!monitor.isSigningIn)
        #expect(monitor.deviceCodeLogin == nil)
        #expect(!service.isRunning)
        await monitor.stop()
    }

    @Test func energySavingModeDefaultsOffForNewMonitor() async {
        let first = UsageMonitor(service: FakeCodexService(), resetAttemptStore: makeResetStore())
        await waitUntil { first.phase == .ready }
        await first.setEnergySavingMode(true)
        #expect(first.energySavingMode)
        await first.stop()

        let second = UsageMonitor(service: FakeCodexService(), resetAttemptStore: makeResetStore())
        #expect(!second.energySavingMode)
        await second.stop()
    }

    @Test func energySavingModeResetUsesTemporaryConnection() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        await monitor.setEnergySavingMode(true)
        await monitor.consumeReset()
        #expect(service.idempotencyKeys.count == 1)
        #expect(!service.isRunning)
        await monitor.stop()
    }

    @Test func failedEnergySavingResetPreservesRecoveryAndStopsConnection() async throws {
        let service = FakeCodexService(resetFailuresBeforeSuccess: 1)
        let store = makeResetStore()
        let monitor = UsageMonitor(service: service, resetAttemptStore: store)
        await waitUntil { monitor.phase == .ready }
        await monitor.setEnergySavingMode(true)
        await monitor.consumeReset()
        #expect(try store.load()?.idempotencyKey == service.idempotencyKeys.first)
        #expect(!service.isRunning)
        await monitor.stop()
    }

    @Test func savingCountdownUpdatesByMinuteThenBySecond() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(countdown(to: now.addingTimeInterval(3_600), now: now, energySaving: true) == "1h 0m")
        #expect(countdown(to: now.addingTimeInterval(61), now: now, energySaving: true) == "2m")
        #expect(countdown(to: now.addingTimeInterval(59), now: now, energySaving: true) == "59s")
        let window = RateLimitWindow(id: "five", limitID: "codex", limitName: nil, kind: "primary",
                                     usedPercent: 50, windowDurationMinutes: 300,
                                     resetsAt: now.addingTimeInterval(61))
        #expect(nextCountdownDelay(windows: [window], now: now) == 1)
        #expect(nextCountdownDelay(windows: [], now: now) == nil)
    }

    @Test func quotaEventSkipsAccountReadButAccountEventDoesNot() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        let originalAccountReads = service.accountFetchCount
        let originalUsageReads = service.usageFetchCount
        service.emit(.rateLimitsChanged)
        await waitUntil { service.usageFetchCount > originalUsageReads }
        #expect(service.accountFetchCount == originalAccountReads)
        service.emit(.accountChanged)
        await waitUntil { service.accountFetchCount > originalAccountReads }
        await monitor.stop()
    }

    @Test func burstOfQuotaEventsUsesOneRead() async {
        let service = FakeCodexService()
        let monitor = UsageMonitor(service: service, resetAttemptStore: makeResetStore())
        await waitUntil { monitor.phase == .ready }
        let originalUsageReads = service.usageFetchCount
        for _ in 0..<5 { service.emit(.rateLimitsChanged) }
        await waitUntil { service.usageFetchCount > originalUsageReads }
        #expect(service.usageFetchCount == originalUsageReads + 1)
        await monitor.stop()
    }

    @Test func authenticationURLAllowlist() {
        #expect(CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://chatgpt.com/auth")!))
        #expect(CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://auth.openai.com/login")!))
        #expect(!CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "http://chatgpt.com/auth")!))
        #expect(!CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://chatgpt.com.example.test/auth")!))
        #expect(!CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://user:secret@chatgpt.com/auth")!))
        #expect(!CodexAppServerClient.isAllowedAuthenticationURL(URL(string: "https://chatgpt.com:8443/auth")!))
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for state")
    }

    private func makeResetStore() -> ResetAttemptStore {
        let suite = "CodexMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ResetAttemptStore(defaults: defaults)
    }
}

private final class FakeCodexService: CodexService {
    var consumedCreditID: String?
    var idempotencyKeys: [String] = []
    var usageFetchCount = 0
    var accountFetchCount = 0
    var usageFailure: CodexMonitorError?
    var isRunning = false
    private var eventContinuation: AsyncStream<CodexServiceEvent>.Continuation?
    private let availableResetCount: Int
    var authType: String
    private var resetFailuresBeforeSuccess: Int
    private let resetFailure: CodexMonitorError

    init(availableResetCount: Int = 1, authType: String = "chatgpt", resetFailuresBeforeSuccess: Int = 0,
         resetFailure: CodexMonitorError = .disconnected) {
        self.availableResetCount = availableResetCount
        self.authType = authType
        self.resetFailuresBeforeSuccess = resetFailuresBeforeSuccess
        self.resetFailure = resetFailure
    }

    func events() async -> AsyncStream<CodexServiceEvent> {
        AsyncStream { continuation in eventContinuation = continuation }
    }
    func emit(_ event: CodexServiceEvent) { eventContinuation?.yield(event) }
    func start() async throws { isRunning = true }
    func stop() async { isRunning = false }
    func fetchAccount() async throws -> AccountSnapshot {
        accountFetchCount += 1
        return AccountSnapshot(account: AccountStatus(authType: authType, email: nil, planType: "plus"), requiresOpenAIAuth: true)
    }
    func fetchUsage() async throws -> UsageSnapshot {
        usageFetchCount += 1
        if let usageFailure { throw usageFailure }
        let resets = availableResetCount > 0 ? [ResetCredit(
            id: "reset-1", resetType: "codexRateLimits", status: "available", grantedAt: nil,
            expiresAt: nil, title: nil, description: nil
        )] : []
        return UsageSnapshot(windows: [], resetCredits: resets, availableResetCount: availableResetCount,
                             credits: nil, fetchedAt: Date())
    }
    func consumeReset(creditID: String?, idempotencyKey: String) async throws -> ResetOutcome {
        consumedCreditID = creditID
        idempotencyKeys.append(idempotencyKey)
        if resetFailuresBeforeSuccess > 0 {
            resetFailuresBeforeSuccess -= 1
            throw resetFailure
        }
        return .reset
    }
    func beginChatGPTLogin() async throws -> BrowserLogin {
        BrowserLogin(loginID: "login-1", url: URL(string: "https://chatgpt.com")!)
    }
    func beginDeviceCodeLogin() async throws -> DeviceCodeLogin {
        DeviceCodeLogin(loginID: "login-1", verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: "ABCD-1234")
    }
    func cancelLogin(loginID: String) async throws {}
}
