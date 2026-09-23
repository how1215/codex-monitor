import Foundation

enum CodexServiceEvent: Equatable {
    case accountChanged
    case loginCompleted(loginID: String, success: Bool, error: String?)
    case rateLimitsChanged
    case disconnected
    case protocolError(String)
}

protocol CodexService: AnyObject {
    func events() async -> AsyncStream<CodexServiceEvent>
    func start() async throws
    func stop() async
    func fetchAccount() async throws -> AccountSnapshot
    func fetchUsage() async throws -> UsageSnapshot
    func consumeReset(creditID: String?, idempotencyKey: String) async throws -> ResetOutcome
    func beginChatGPTLogin() async throws -> BrowserLogin
    func beginDeviceCodeLogin() async throws -> DeviceCodeLogin
    func cancelLogin(loginID: String) async throws
}

struct JSONLMessageBuffer {
    private var buffer = Data()
    private let maximumLineSize = 1_048_576

    mutating func append(_ data: Data) -> ([[String: Any]], Bool) {
        buffer.append(data)
        var messages: [[String: Any]] = []
        var malformed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= maximumLineSize,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                malformed = true
                continue
            }
            messages.append(object)
        }
        if buffer.count > maximumLineSize {
            buffer.removeAll(keepingCapacity: false)
            malformed = true
        }
        return (messages, malformed)
    }
}

actor CodexAppServerClient: CodexService {
    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let requestTimeout: Duration
    private let transport: AppServerTransport
    private var outputBuffer = JSONLMessageBuffer()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var eventContinuation: AsyncStream<CodexServiceEvent>.Continuation?
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var outputTask: Task<Void, Never>?
    private var connectionGeneration = 0

    init(requestTimeout: Duration = .seconds(15), transport: AppServerTransport = ProcessAppServerTransport()) {
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    func events() -> AsyncStream<CodexServiceEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            eventContinuation = continuation
        }
    }

    func start() async throws {
        if transport.isRunning { return }
        try launch()

        do {
            _ = try await request(method: "initialize", params: [
                "clientInfo": [
                    "name": "codex_usage_monitor",
                    "title": "Codex Usage Monitor",
                    "version": Self.appVersion
                ]
            ])
            try sendNotification(method: "initialized", params: [:])
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        connectionGeneration += 1
        outputContinuation?.finish()
        outputContinuation = nil
        outputTask?.cancel()
        outputTask = nil
        transport.stop()
        failPending(with: CodexMonitorError.disconnected)
        outputBuffer = JSONLMessageBuffer()
    }

    func fetchAccount() async throws -> AccountSnapshot {
        let result = try await request(method: "account/read", params: ["refreshToken": false])
        return try UsageParser.account(from: result)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let result = try await request(method: "account/rateLimits/read", params: [:])
        return try UsageParser.usage(from: result)
    }

    func consumeReset(creditID: String?, idempotencyKey: String) async throws -> ResetOutcome {
        guard !idempotencyKey.isEmpty else {
            throw CodexMonitorError.invalidResponse("Reset idempotency key cannot be empty")
        }
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditID { params["creditId"] = creditID }
        let result = try await request(method: "account/rateLimitResetCredit/consume", params: params)
        guard let raw = result["outcome"] as? String, let outcome = ResetOutcome(rawValue: raw) else {
            throw CodexMonitorError.invalidResponse("Missing reset outcome")
        }
        return outcome
    }

    func beginChatGPTLogin() async throws -> BrowserLogin {
        let result = try await request(method: "account/login/start", params: [
            "type": "chatgpt",
            "useHostedLoginSuccessPage": true,
            "appBrand": "codex"
        ])
        guard
            let loginID = result["loginId"] as? String, !loginID.isEmpty,
            let rawURL = result["authUrl"] as? String,
            let url = URL(string: rawURL),
            Self.isAllowedAuthenticationURL(url)
        else {
            throw CodexMonitorError.invalidResponse("Login URL failed security validation")
        }
        return BrowserLogin(loginID: loginID, url: url)
    }

    func beginDeviceCodeLogin() async throws -> DeviceCodeLogin {
        let result = try await request(method: "account/login/start", params: ["type": "chatgptDeviceCode"])
        guard let loginID = result["loginId"] as? String, !loginID.isEmpty,
              let code = result["userCode"] as? String, !code.isEmpty,
              let rawURL = result["verificationUrl"] as? String,
              let url = URL(string: rawURL), Self.isAllowedAuthenticationURL(url) else {
            throw CodexMonitorError.invalidResponse("Invalid device-code login response")
        }
        return DeviceCodeLogin(loginID: loginID, verificationURL: url, userCode: code)
    }

    func cancelLogin(loginID: String) async throws {
        _ = try await request(method: "account/login/cancel", params: ["loginId": loginID])
    }

    private func launch() throws {
        connectionGeneration += 1
        let generation = connectionGeneration
        let (outputStream, continuation) = AsyncStream<Data>.makeStream()
        outputContinuation = continuation
        do {
            try transport.start(onData: { data in continuation.yield(data) }, onTermination: { [weak self] in
                Task { await self?.transportTerminated(generation: generation) }
            })
        } catch {
            continuation.finish()
            outputContinuation = nil
            throw error
        }
        outputTask = Task { [weak self] in
            for await data in outputStream { await self?.receive(data) }
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard transport.isRunning else { throw CodexMonitorError.disconnected }
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
        guard transport.isRunning else {
            throw CodexMonitorError.disconnected
        }
        guard JSONSerialization.isValidJSONObject(message) else {
            throw CodexMonitorError.invalidResponse("Could not encode request")
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try transport.send(data)
    }

    private func receive(_ data: Data) {
        let (messages, malformed) = outputBuffer.append(data)
        if malformed { eventContinuation?.yield(.protocolError("Codex App Server returned malformed JSONL.")) }
        for message in messages { handle(message) }
    }

    private func handle(_ message: [String: Any]) {
        if let id = (message["id"] as? NSNumber)?.intValue, let request = pending.removeValue(forKey: id) {
            request.timeoutTask?.cancel()
            if let error = message["error"] as? [String: Any] {
                request.continuation.resume(
                    throwing: CodexMonitorError.server(error["message"] as? String ?? "Codex request failed")
                )
            } else if let result = message["result"] as? [String: Any] {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(
                    throwing: CodexMonitorError.invalidResponse("Request \(id) has no result")
                )
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method == "account/rateLimits/updated" { eventContinuation?.yield(.rateLimitsChanged) }
        if method == "account/updated" { eventContinuation?.yield(.accountChanged) }
        if method == "account/login/completed", let params = message["params"] as? [String: Any],
           let loginID = params["loginId"] as? String, let success = params["success"] as? Bool {
            eventContinuation?.yield(.loginCompleted(
                loginID: loginID, success: success, error: params["error"] as? String
            ))
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

    private func transportTerminated(generation: Int) {
        guard generation == connectionGeneration else { return }
        outputContinuation?.finish()
        outputContinuation = nil
        outputTask?.cancel()
        outputTask = nil
        failPending(with: CodexMonitorError.disconnected)
        transport.stop()
        outputBuffer = JSONLMessageBuffer()
        eventContinuation?.yield(.disconnected)
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
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil else { return false }
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
        if let path = candidates.first(where: { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: candidate)
        }) {
            return URL(fileURLWithPath: path)
        }
        throw CodexMonitorError.cliNotFound
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
