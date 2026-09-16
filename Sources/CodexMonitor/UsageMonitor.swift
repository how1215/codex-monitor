import AppKit
import Foundation
import ServiceManagement

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var phase: MonitorPhase = .loading
    @Published private(set) var account: AccountStatus?
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isResetting = false
    @Published private(set) var hasPendingResetAttempt = false
    @Published private(set) var message: String?
    @Published var launchAtLogin = false

    private let service: CodexService
    private let resetAttemptStore: ResetAttemptStore
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var refreshRequested = false
    private var hasStarted = false

    init(
        service: CodexService = CodexAppServerClient(),
        resetAttemptStore: ResetAttemptStore? = nil
    ) {
        self.service = service
        self.resetAttemptStore = resetAttemptStore ?? ResetAttemptStore()
        hasPendingResetAttempt = self.resetAttemptStore.load() != nil
        launchAtLogin = SMAppService.mainApp.status == .enabled
        start()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        eventTask = Task { [weak self, service] in
            let events = await service.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        connect()
    }

    func stop() {
        hasStarted = false
        eventTask?.cancel()
        connectionTask?.cancel()
        pollingTask?.cancel()
        reconnectTask?.cancel()
        Task { await service.stop() }
    }

    func connect() {
        reconnectAttempt = 0
        reconnectTask?.cancel()
        beginConnection()
    }

    func refresh() async {
        if isRefreshing {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                Task { await self.refresh() }
            }
        }

        do {
            let fetchedAccount = try await service.fetchAccount()
            account = fetchedAccount
            guard fetchedAccount != nil else {
                phase = .signedOut
                message = nil
                return
            }
            let fetchedUsage = try await service.fetchUsage()
            usage = fetchedUsage
            phase = .ready
            message = nil
        } catch is CancellationError {
            return
        } catch {
            phase = usage == nil ? .offline : .stale
            message = error.localizedDescription
        }
    }

    func signIn() async {
        do {
            let url = try await service.beginChatGPTLogin()
            NSWorkspace.shared.open(url)
        } catch {
            message = error.localizedDescription
        }
    }

    func consumeReset() async {
        guard
            !isResetting,
            let usage,
            usage.availableResetCount > 0 || hasPendingResetAttempt
        else { return }
        isResetting = true
        defer { isResetting = false }

        let attempt: PendingResetAttempt
        if let pendingAttempt = resetAttemptStore.load() {
            attempt = pendingAttempt
        } else {
            attempt = PendingResetAttempt(
                idempotencyKey: UUID().uuidString,
                creditID: usage.resetCredits.first(where: { $0.status == "available" })?.id,
                startedAt: Date()
            )
            do {
                try resetAttemptStore.save(attempt)
                hasPendingResetAttempt = true
            } catch {
                message = "無法安全保存 Reset 狀態，因此未送出重置要求。"
                return
            }
        }

        do {
            let outcome = try await service.consumeReset(
                creditID: attempt.creditID,
                idempotencyKey: attempt.idempotencyKey
            )
            resetAttemptStore.clear()
            hasPendingResetAttempt = false
            let outcomeMessage: String
            switch outcome {
            case .reset: outcomeMessage = "用量已重置。"
            case .alreadyRedeemed: outcomeMessage = "此重置已完成。"
            case .nothingToReset: outcomeMessage = "目前沒有需要重置的用量視窗。"
            case .noCredit: outcomeMessage = "帳號目前沒有可用的 reset。"
            }
            await refresh()
            message = outcomeMessage
        } catch {
            message = "Reset 結果尚未確認。再次操作時會安全重用同一個識別碼。\n\(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            message = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "無法更新開機啟動設定：\(error.localizedDescription)"
        }
    }

    private func beginConnection() {
        connectionTask?.cancel()
        phase = usage == nil ? .loading : .stale
        connectionTask = Task { [weak self, service] in
            guard let self else { return }
            do {
                try await service.start()
                reconnectAttempt = 0
                await refresh()
                startPolling()
            } catch is CancellationError {
                return
            } catch let error as CodexMonitorError where error == .cliNotFound {
                phase = .cliMissing
                message = error.localizedDescription
            } catch {
                phase = usage == nil ? .offline : .stale
                message = error.localizedDescription
                scheduleReconnect()
            }
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func handle(_ event: CodexServiceEvent) async {
        switch event {
        case .dataChanged:
            await refresh()
        case .disconnected:
            pollingTask?.cancel()
            phase = usage == nil ? .offline : .stale
            scheduleReconnect()
        case .protocolError(let detail):
            phase = usage == nil ? .offline : .stale
            message = detail
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = ReconnectPolicy.delaySeconds(forAttempt: reconnectAttempt)
        message = "連線中斷，約 \(Int(ceil(delay))) 秒後重新連線。"
        reconnectTask = Task { [weak self, service] in
            do {
                try await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await service.stop()
            beginConnection()
        }
    }
}
