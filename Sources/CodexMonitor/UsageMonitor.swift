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
    @Published private(set) var energySavingMode = false
    @Published private(set) var isSwitchingMode = false
    @Published private(set) var isManualOperationInProgress = false
    @Published private(set) var isSigningIn = false
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
    private var manualOperations = 0
    private var manualStartTask: Task<Void, Error>?
    private var pendingLoginID: String?
    private var loginTimeoutTask: Task<Void, Never>?
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
            Task { @MainActor [weak self] in
                guard let self, !self.energySavingMode else { return }
                await self.refresh()
            }
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
        loginTimeoutTask?.cancel()
        manualStartTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        await service.stop()
    }

    func connect() {
        if energySavingMode {
            Task { await refresh() }
            return
        }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        beginConnection()
    }

    func refresh() async {
        if energySavingMode {
            guard !isManualOperationInProgress, !isSigningIn, !isSwitchingMode else { return }
            isManualOperationInProgress = true
            defer { isManualOperationInProgress = false }
            do {
                try await beginManualOperation()
                await refresh(includeAccount: true)
                await endManualOperation()
            } catch {
                phase = usage == nil ? .offline : .stale
                message = error.localizedDescription
            }
            return
        }
        await refresh(includeAccount: true)
    }

    func setEnergySavingMode(_ enabled: Bool) async {
        guard enabled != energySavingMode, !isSwitchingMode, !isRefreshing,
              !isResetting, !isManualOperationInProgress, !isSigningIn else { return }
        isSwitchingMode = true
        defer { isSwitchingMode = false }
        energySavingMode = enabled
        if enabled {
            connectionTask?.cancel()
            pollingTask?.cancel()
            reconnectTask?.cancel()
            eventRefreshTask?.cancel()
            refreshRequested = false
            refreshNeedsAccount = false
            eventNeedsAccount = false
            await service.stop()
            if usage != nil { phase = .stale }
            message = nil
        } else {
            connect()
        }
    }

    func refreshIfNeededOnOpen(now: Date = Date()) async {
        guard !energySavingMode, let fetchedAt = usage?.fetchedAt,
              now.timeIntervalSince(fetchedAt) > 60,
              lastPanelOpenRefreshAt.map({ now.timeIntervalSince($0) > 60 }) ?? true,
              !isRefreshing,
              phase == .ready || phase == .stale else { return }
        lastPanelOpenRefreshAt = now
        await refresh(includeAccount: false)
    }

    private func refresh(includeAccount: Bool) async {
        guard !energySavingMode || manualOperations > 0 else { return }
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
        guard !isSigningIn, !isManualOperationInProgress, !isSwitchingMode else { return }
        let temporary = energySavingMode
        isManualOperationInProgress = true
        defer { isManualOperationInProgress = false }
        var acquired = false
        do {
            if temporary {
                try await beginManualOperation()
                acquired = true
            }
            let login = try await service.beginChatGPTLogin()
            beginLoginSession(login.loginID)
            if !NSWorkspace.shared.open(login.url) {
                await cancelLogin()
                message = "Could not open the browser. Use device-code sign-in instead."
            }
        } catch {
            message = error.localizedDescription
        }
        if acquired { await endManualOperation() }
    }

    func signInWithDeviceCode() async {
        guard !isSigningIn, !isManualOperationInProgress, !isSwitchingMode else { return }
        let temporary = energySavingMode
        isManualOperationInProgress = true
        defer { isManualOperationInProgress = false }
        var acquired = false
        do {
            if temporary {
                try await beginManualOperation()
                acquired = true
            }
            deviceCodeLogin = try await service.beginDeviceCodeLogin()
            if let deviceCodeLogin { beginLoginSession(deviceCodeLogin.loginID) }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        if acquired { await endManualOperation() }
    }

    func cancelLogin() async {
        guard let loginID = pendingLoginID else { return }
        clearLoginSession()
        do { try await service.cancelLogin(loginID: loginID) }
        catch { message = error.localizedDescription }
        await stopManualServiceIfIdle()
    }

    func discardResetRecovery() {
        resetAttemptStore.clear()
        resetRecoveryBlocked = false
        hasPendingResetAttempt = false
        message = "Reset recovery record discarded. Verify your account before another reset."
    }

    func consumeReset() async {
        guard
            !isResetting, !isManualOperationInProgress, !isSigningIn,
            !isSwitchingMode, !resetRecoveryBlocked,
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

        if energySavingMode {
            do { try await beginManualOperation() }
            catch {
                message = "Could not connect. No reset request was sent.\n\(error.localizedDescription)"
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
            await refresh(includeAccount: true)
            message = outcomeMessage
        } catch {
            message = "Reset outcome is unconfirmed. Retrying will reuse the same identifier.\n\(error.localizedDescription)"
        }
        if energySavingMode { await endManualOperation() }
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

    private func beginManualOperation() async throws {
        manualOperations += 1
        let task: Task<Void, Error>
        if let manualStartTask {
            task = manualStartTask
        } else {
            task = Task { try await service.start() }
            manualStartTask = task
        }
        do { try await task.value }
        catch {
            manualOperations -= 1
            manualStartTask = nil
            await stopManualServiceIfIdle()
            throw error
        }
        manualStartTask = nil
    }

    private func endManualOperation() async {
        guard manualOperations > 0 else { return }
        manualOperations -= 1
        await stopManualServiceIfIdle()
    }

    private func stopManualServiceIfIdle() async {
        if energySavingMode && manualOperations == 0 && pendingLoginID == nil {
            await service.stop()
        }
    }

    private func beginLoginSession(_ loginID: String) {
        pendingLoginID = loginID
        isSigningIn = true
        loginTimeoutTask?.cancel()
        loginTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) }
            catch { return }
            guard let self else { return }
            await self.cancelLogin()
            self.message = "Sign-in timed out. Try again."
        }
    }

    private func clearLoginSession() {
        pendingLoginID = nil
        isSigningIn = false
        deviceCodeLogin = nil
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
    }

    private func beginConnection() {
        connectionTask?.cancel()
        codexPath = (try? CodexAppServerClient.locateCodex())?.path
        phase = usage == nil ? .loading : .stale
        connectionTask = Task { [weak self, service] in
            guard let self else { return }
            do {
                try await service.start()
                guard !Task.isCancelled, !energySavingMode else { return }
                reconnectAttempt = 0
                await refresh()
                guard !Task.isCancelled, !energySavingMode else { return }
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
        guard !energySavingMode else { return }
        pollingTask?.cancel()
        let pollingInterval = self.pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, self?.energySavingMode == false else { return }
                await self?.refresh()
            }
        }
    }

    private func handle(_ event: CodexServiceEvent) async {
        if case .loginCompleted(let loginID, let success, let error) = event {
            guard pendingLoginID == loginID else {
                if !energySavingMode && success { scheduleEventRefresh(includeAccount: true) }
                return
            }
            clearLoginSession()
            if success {
                if energySavingMode {
                    do {
                        try await beginManualOperation()
                        await refresh(includeAccount: true)
                        await endManualOperation()
                    } catch {
                        phase = usage == nil ? .offline : .stale
                        message = error.localizedDescription
                    }
                } else {
                    scheduleEventRefresh(includeAccount: true)
                }
            } else {
                message = error ?? "Sign-in was not completed."
            }
            await stopManualServiceIfIdle()
            return
        }
        guard !energySavingMode else { return }
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
        case .loginCompleted:
            break
        }
    }

    private func scheduleEventRefresh(includeAccount: Bool) {
        guard !energySavingMode else { return }
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
        guard !energySavingMode else { return }
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
