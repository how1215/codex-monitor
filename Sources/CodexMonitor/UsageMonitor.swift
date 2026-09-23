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
    @Published private(set) var resetRecoveryBlocked = false
    @Published private(set) var deviceCodeLogin: DeviceCodeLogin?
    @Published private(set) var codexPath: String?
    @Published private(set) var message: String?
    @Published var launchAtLogin = false

    private let service: CodexService
    private let resetAttemptStore: ResetAttemptStore
    private let pollingInterval: Duration
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var refreshRequested = false
    private var refreshNeedsAccount = false
    private var eventNeedsAccount = false
    private var lastPanelOpenRefreshAt: Date?
    private var hasStarted = false
    private var wakeObserver: NSObjectProtocol?

    init(
        service: CodexService = CodexAppServerClient(),
        resetAttemptStore: ResetAttemptStore? = nil,
        pollingInterval: Duration = .seconds(300)
    ) {
        self.service = service
        self.resetAttemptStore = resetAttemptStore ?? ResetAttemptStore()
        self.pollingInterval = pollingInterval
        do { hasPendingResetAttempt = try self.resetAttemptStore.load() != nil }
        catch { resetRecoveryBlocked = true }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        start()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        eventTask = Task { [weak self, service] in
            let events = await service.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        connect()
    }

    func stop() async {
        hasStarted = false
        eventTask?.cancel()
        connectionTask?.cancel()
        pollingTask?.cancel()
        reconnectTask?.cancel()
        eventRefreshTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        await service.stop()
    }

    func connect() {
        reconnectAttempt = 0
        reconnectTask?.cancel()
        beginConnection()
    }

    func refresh() async {
        await refresh(includeAccount: true)
    }

    func refreshIfNeededOnOpen(now: Date = Date()) async {
        guard let fetchedAt = usage?.fetchedAt,
              now.timeIntervalSince(fetchedAt) > 60,
              lastPanelOpenRefreshAt.map({ now.timeIntervalSince($0) > 60 }) ?? true,
              !isRefreshing,
              phase == .ready || phase == .stale else { return }
        lastPanelOpenRefreshAt = now
        await refresh(includeAccount: false)
    }

    private func refresh(includeAccount: Bool) async {
        if isRefreshing {
            refreshRequested = true
            refreshNeedsAccount = refreshNeedsAccount || includeAccount
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                let needsAccount = refreshNeedsAccount
                refreshRequested = false
                refreshNeedsAccount = false
                Task { await self.refresh(includeAccount: needsAccount) }
            }
        }

        do {
            if includeAccount || account == nil {
                let snapshot = try await service.fetchAccount()
                account = snapshot.account
                guard let fetchedAccount = snapshot.account else {
                    usage = nil
                    phase = snapshot.requiresOpenAIAuth ? .signedOut : .unsupportedAuth
                    message = nil
                    return
                }
                guard fetchedAccount.authType == "chatgpt" else {
                    usage = nil
                    phase = .unsupportedAuth
                    message = "Sign in to Codex with ChatGPT to view subscription limits."
                    return
                }
            }
            let fetchedUsage = try await service.fetchUsage()
            usage = fetchedUsage
            phase = .ready
            deviceCodeLogin = nil
            message = nil
        } catch is CancellationError {
            return
        } catch let error as CodexMonitorError {
            if case .invalidResponse = error { phase = .incompatibleResponse }
            else { phase = usage == nil ? .offline : .stale }
            message = error.localizedDescription
        } catch {
            phase = usage == nil ? .offline : .stale
            message = error.localizedDescription
        }
    }

    func signIn() async {
        do {
            let url = try await service.beginChatGPTLogin()
            guard NSWorkspace.shared.open(url) else {
                message = "Could not open the browser. Use device-code sign-in instead."
                return
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func signInWithDeviceCode() async {
        do {
            deviceCodeLogin = try await service.beginDeviceCodeLogin()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func discardResetRecovery() {
        resetAttemptStore.clear()
        resetRecoveryBlocked = false
        hasPendingResetAttempt = false
        message = "Reset recovery record discarded. Verify your account before another reset."
    }

    func consumeReset() async {
        guard
            !isResetting, !resetRecoveryBlocked,
            let usage,
            usage.availableResetCount > 0 || hasPendingResetAttempt
        else { return }
        isResetting = true
        defer { isResetting = false }

        let attempt: PendingResetAttempt
        let pendingAttempt: PendingResetAttempt?
        do { pendingAttempt = try resetAttemptStore.load() }
        catch {
            resetRecoveryBlocked = true
            message = error.localizedDescription
            return
        }
        if let pendingAttempt {
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
                message = "Could not safely save reset state. No reset request was sent."
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
            case .reset: outcomeMessage = "Usage was reset."
            case .alreadyRedeemed: outcomeMessage = "This reset was already completed."
            case .nothingToReset: outcomeMessage = "No eligible usage window needs a reset."
            case .noCredit: outcomeMessage = "No earned reset is available."
            }
            await refresh()
            message = outcomeMessage
        } catch {
            message = "Reset outcome is unconfirmed. Retrying will reuse the same identifier.\n\(error.localizedDescription)"
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
            message = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    private func beginConnection() {
        connectionTask?.cancel()
        codexPath = (try? CodexAppServerClient.locateCodex())?.path
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
            } catch let error as CodexMonitorError {
                if case .invalidResponse = error { phase = .incompatibleResponse }
                else { phase = usage == nil ? .offline : .stale }
                message = error.localizedDescription
                scheduleReconnect()
            } catch {
                phase = usage == nil ? .offline : .stale
                message = error.localizedDescription
                scheduleReconnect()
            }
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        let pollingInterval = self.pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollingInterval)
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
        case .accountChanged:
            scheduleEventRefresh(includeAccount: true)
        case .rateLimitsChanged:
            scheduleEventRefresh(includeAccount: false)
        case .disconnected:
            pollingTask?.cancel()
            phase = usage == nil ? .offline : .stale
            scheduleReconnect()
        case .protocolError(let detail):
            phase = usage == nil ? .offline : .stale
            message = detail
        }
    }

    private func scheduleEventRefresh(includeAccount: Bool) {
        eventNeedsAccount = eventNeedsAccount || includeAccount
        guard eventRefreshTask == nil else { return }
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let needsAccount = eventNeedsAccount
            eventNeedsAccount = false
            eventRefreshTask = nil
            await refresh(includeAccount: needsAccount)
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = ReconnectPolicy.delaySeconds(forAttempt: reconnectAttempt)
        message = "Connection lost. Reconnecting in about \(Int(ceil(delay))) seconds."
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
