import Foundation

enum CodexServiceEvent: Equatable {
    case dataChanged
    case disconnected
    case protocolError(String)
}

protocol CodexService: AnyObject {
    func events() async -> AsyncStream<CodexServiceEvent>
    func start() async throws
    func stop() async
    func fetchAccount() async throws -> AccountStatus?
    func fetchUsage() async throws -> UsageSnapshot
    func consumeReset(creditID: String?, idempotencyKey: String) async throws -> ResetOutcome
    func beginChatGPTLogin() async throws -> URL
}

actor CodexAppServerClient: CodexService {
    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let requestTimeout: Duration
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var eventContinuation: AsyncStream<CodexServiceEvent>.Continuation?
    private var stopping = false

    init(requestTimeout: Duration = .seconds(15)) {
        self.requestTimeout = requestTimeout
    }

    func events() -> AsyncStream<CodexServiceEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            eventContinuation = continuation
        }
    }

    func start() async throws {
        if process?.isRunning == true { return }
        let executable = try Self.locateCodex()
        try launch(executable: executable)

        _ = try await request(method: "initialize", params: [
            "clientInfo": [
                "name": "codex_usage_monitor",
                "title": "Codex Usage Monitor",
                "version": Self.appVersion
            ]
        ])
        try sendNotification(method: "initialized", params: [:])
    }

    func stop() {
        stopping = true
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        failPending(with: CodexMonitorError.disconnected)
        process = nil
        input = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: false)
        stopping = false
    }

    func fetchAccount() async throws -> AccountStatus? {
        let result = try await request(method: "account/read", params: ["refreshToken": false])
        return try UsageParser.account(from: result)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let result = try await request(method: "account/rateLimits/read", params: [:])
        return try UsageParser.usage(from: result)
    }

    func consumeReset(creditID: String?, idempotencyKey: String) async throws -> ResetOutcome {
        guard !idempotencyKey.isEmpty else {
            throw CodexMonitorError.invalidResponse("Reset idempotency key 不可為空")
        }
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditID { params["creditId"] = creditID }
        let result = try await request(method: "account/rateLimitResetCredit/consume", params: params)
        guard let raw = result["outcome"] as? String, let outcome = ResetOutcome(rawValue: raw) else {
            throw CodexMonitorError.invalidResponse("缺少 reset outcome")
        }
        return outcome
    }

    func beginChatGPTLogin() async throws -> URL {
        let result = try await request(method: "account/login/start", params: [
            "type": "chatgpt",
            "useHostedLoginSuccessPage": true,
            "appBrand": "codex"
        ])
        guard
            let rawURL = result["authUrl"] as? String,
            let url = URL(string: rawURL),
            Self.isAllowedAuthenticationURL(url)
        else {
            throw CodexMonitorError.invalidResponse("登入網址未通過安全檢查")
        }
        return url
    }

    private func launch(executable: URL) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            Task { await self?.processTerminated(process) }
        }

        do {
            try process.run()
            self.process = process
            self.input = input
            self.output = output
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw CodexMonitorError.processLaunch(error.localizedDescription)
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw CodexMonitorError.disconnected }
        let id = nextRequestID
        nextRequestID += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(continuation: continuation, timeoutTask: nil)
                do {
                    try write(["method": method, "id": id, "params": params])
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                    return
                }

                let timeout = requestTimeout
                pending[id]?.timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(id: id, method: method)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try write(["method": method, "params": params])
    }

    private func write(_ message: [String: Any]) throws {
        guard process?.isRunning == true, let input else {
            throw CodexMonitorError.disconnected
        }
        guard JSONSerialization.isValidJSONObject(message) else {
            throw CodexMonitorError.invalidResponse("無法編碼 request")
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                eventContinuation?.yield(.protocolError("Codex App Server 傳回無法解析的 JSONL 訊息。"))
                continue
            }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = (message["id"] as? NSNumber)?.intValue, let request = pending.removeValue(forKey: id) {
            request.timeoutTask?.cancel()
            if let error = message["error"] as? [String: Any] {
                request.continuation.resume(
                    throwing: CodexMonitorError.server(error["message"] as? String ?? "Codex request 失敗")
                )
            } else if let result = message["result"] as? [String: Any] {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(
                    throwing: CodexMonitorError.invalidResponse("request \(id) 沒有 result")
                )
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method == "account/rateLimits/updated" || method == "account/updated" || method == "account/login/completed" {
            eventContinuation?.yield(.dataChanged)
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CodexMonitorError.requestTimedOut(method))
    }

    private func cancelRequest(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func processTerminated(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        failPending(with: CodexMonitorError.disconnected)
        process = nil
        input = nil
        output = nil
        if !stopping { eventContinuation?.yield(.disconnected) }
    }

    private func failPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    static func isAllowedAuthenticationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
            || host == "openai.com"
            || host.hasSuffix(".openai.com")
    }

    static func locateCodex() throws -> URL {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = environmentPath.split(separator: ":").map { String($0) + "/codex" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = pathCandidates + [
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw CodexMonitorError.cliNotFound
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
