import Foundation
import Testing
@testable import CodexMonitor

struct AppServerClientTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_MONITOR_REAL_SMOKE"] == "1"))
    func readOnlyInstalledCodexSmoke() async throws {
        let client = CodexAppServerClient()
        do {
            try await client.start()
            let snapshot = try await client.fetchAccount()
            if snapshot.account?.authType == "chatgpt" {
                let usage = try await client.fetchUsage()
                #expect(usage.availableResetCount >= 0)
            }
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }

    @Test func correlatesResponsesByID() async throws {
        let transport = FakeAppServerTransport()
        transport.onRequest = { message in
            guard message["method"] as? String == "account/read",
                  let id = message["id"] as? Int else { return }
            transport.reply(id: id + 100, result: ["account": NSNull(), "requiresOpenaiAuth": true])
            transport.reply(id: id, result: ["account": ["type": "chatgpt", "planType": "plus"], "requiresOpenaiAuth": true])
        }
        let client = CodexAppServerClient(transport: transport)
        try await client.start()
        let snapshot = try await client.fetchAccount()
        #expect(snapshot.account?.planLabel == "Plus")
        await client.stop()
    }

    @Test func timesOutAndIgnoresLateResponse() async throws {
        let transport = FakeAppServerTransport()
        let client = CodexAppServerClient(requestTimeout: .milliseconds(30), transport: transport)
        try await client.start()
        do {
            _ = try await client.fetchUsage()
            Issue.record("Expected timeout")
        } catch let error as CodexMonitorError {
            #expect(error == .requestTimedOut("account/rateLimits/read"))
        }
        if let id = transport.lastRequestID(for: "account/rateLimits/read") {
            transport.reply(id: id, result: [:])
        }
        await client.stop()
    }

    @Test func cancellationRemovesPendingRequest() async throws {
        let transport = FakeAppServerTransport()
        let client = CodexAppServerClient(requestTimeout: .seconds(2), transport: transport)
        try await client.start()
        let task = Task { try await client.fetchUsage() }
        await waitUntil { transport.lastRequestID(for: "account/rateLimits/read") != nil }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await client.stop()
    }

    @Test func processTerminationFailsPendingRequest() async throws {
        let transport = FakeAppServerTransport()
        let client = CodexAppServerClient(requestTimeout: .seconds(2), transport: transport)
        try await client.start()
        let task = Task { try await client.fetchUsage() }
        await waitUntil { transport.lastRequestID(for: "account/rateLimits/read") != nil }
        transport.terminate()
        do {
            _ = try await task.value
            Issue.record("Expected disconnection")
        } catch let error as CodexMonitorError {
            #expect(error == .disconnected)
        }
        await client.stop()
    }

    @Test func serverErrorAndMalformedResponse() async throws {
        let transport = FakeAppServerTransport()
        transport.onRequest = { message in
            guard message["method"] as? String == "account/read", let id = message["id"] as? Int else { return }
            transport.emit(Data("not-json\n".utf8))
            transport.reply(id: id, error: "No account")
        }
        let client = CodexAppServerClient(transport: transport)
        let events = await client.events()
        try await client.start()
        do {
            _ = try await client.fetchAccount()
            Issue.record("Expected server error")
        } catch let error as CodexMonitorError {
            #expect(error == .server("No account"))
        }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .protocolError("Codex App Server returned malformed JSONL."))
        await client.stop()
    }

    @Test func stopFailsPendingRequest() async throws {
        let transport = FakeAppServerTransport()
        let client = CodexAppServerClient(requestTimeout: .seconds(2), transport: transport)
        try await client.start()
        let task = Task { try await client.fetchUsage() }
        await waitUntil { transport.lastRequestID(for: "account/rateLimits/read") != nil }
        await client.stop()
        do {
            _ = try await task.value
            Issue.record("Expected disconnection")
        } catch let error as CodexMonitorError {
            #expect(error == .disconnected)
        }
        #expect(!transport.isRunning)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for request")
    }
}

private final class FakeAppServerTransport: AppServerTransport {
    private(set) var isRunning = false
    private var onData: ((Data) -> Void)?
    private var onTermination: (() -> Void)?
    private var sent: [[String: Any]] = []
    var onRequest: (([String: Any]) -> Void)?

    func start(onData: @escaping (Data) -> Void, onTermination: @escaping () -> Void) throws {
        isRunning = true
        self.onData = onData
        self.onTermination = onTermination
    }

    func send(_ data: Data) throws {
        guard isRunning else { throw CodexMonitorError.disconnected }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexMonitorError.invalidResponse("Invalid test request")
        }
        sent.append(message)
        if message["method"] as? String == "initialize", let id = message["id"] as? Int {
            reply(id: id, result: [:])
        } else {
            onRequest?(message)
        }
    }

    func stop() {
        isRunning = false
        onData = nil
        onTermination = nil
    }

    func terminate() {
        isRunning = false
        onTermination?()
    }

    func lastRequestID(for method: String) -> Int? {
        sent.last(where: { $0["method"] as? String == method })?["id"] as? Int
    }

    func emit(_ data: Data) { onData?(data) }

    func reply(id: Int, result: [String: Any]) {
        emitJSON(["id": id, "result": result])
    }

    func reply(id: Int, error: String) {
        emitJSON(["id": id, "error": ["code": -1, "message": error]])
    }

    private func emitJSON(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        emit(data + Data([0x0A]))
    }
}
