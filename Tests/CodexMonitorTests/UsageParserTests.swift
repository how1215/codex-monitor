import Foundation
import Testing
@testable import CodexMonitor

struct UsageParserTests {
    @Test func parsesAccountAndMultiWindowUsage() throws {
        let snapshot = try UsageParser.account(from: [
            "account": ["type": "chatgpt", "email": "user@example.com", "planType": "pro"],
            "requiresOpenaiAuth": true
        ])
        #expect(snapshot.account?.planLabel == "Pro")
        #expect(snapshot.requiresOpenAIAuth)

        let now = Date(timeIntervalSince1970: 100)
        let usage = try UsageParser.usage(from: [
            "rateLimitsByLimitId": ["codex": [
                "limitId": "codex", "limitName": NSNull(),
                "credits": ["hasCredits": true, "unlimited": false, "balance": "12.50"],
                "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_000],
                "secondary": ["usedPercent": 40.5, "windowDurationMins": 10_080, "resetsAt": 2_000]
            ]],
            "rateLimitResetCredits": ["availableCount": 1, "credits": [[
                "id": "reset-1", "resetType": "codexRateLimits", "status": "available",
                "grantedAt": 50, "expiresAt": 3_000, "title": "Full reset"
            ]]]
        ], now: now)
        #expect(usage.windows.count == 2)
        #expect(usage.windows[0].durationLabel == "5-hour window")
        #expect(usage.windows[1].durationLabel == "1-week window")
        #expect(usage.windows[1].usedPercent == 40.5)
        #expect(usage.availableResetCount == 1)
        #expect(usage.resetCredits.first?.id == "reset-1")
        #expect(usage.credits?.balance == "12.50")
        #expect(usage.fetchedAt == now)
    }

    @Test func legacyRateLimitAndClamp() throws {
        let usage = try UsageParser.usage(from: ["rateLimits": [
            "limitId": "codex", "primary": ["usedPercent": 125, "windowDurationMins": 60, "resetsAt": 1_000]
        ]])
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedPercent == 100)
        #expect(usage.windows[0].remainingPercent == 0)
    }

    @Test func missingAccountMeansSignedOut() throws {
        let snapshot = try UsageParser.account(from: ["account": NSNull(), "requiresOpenaiAuth": true])
        #expect(snapshot.account == nil)
    }

    @Test func missingAuthFieldIsIncompatible() {
        #expect(throws: CodexMonitorError.self) { try UsageParser.account(from: ["account": NSNull()]) }
    }

    @Test func ignoresMalformedWindows() throws {
        let usage = try UsageParser.usage(from: ["rateLimits": [
            "limitId": "codex", "primary": ["usedPercent": 20]
        ]])
        #expect(usage.windows.isEmpty)
    }

    @Test func jsonlHandlesPartialAndMultipleLines() {
        var buffer = JSONLMessageBuffer()
        let first = buffer.append(Data("{\"id\":1".utf8))
        #expect(first.0.isEmpty)
        #expect(!first.1)
        let second = buffer.append(Data("}\n{\"id\":2}\n".utf8))
        #expect(second.0.count == 2)
        #expect(second.0[0]["id"] as? Int == 1)
        #expect(second.0[1]["id"] as? Int == 2)
        #expect(!second.1)
    }

    @Test func jsonlReportsMalformedAndRecovers() {
        var buffer = JSONLMessageBuffer()
        let result = buffer.append(Data("not json\n{\"id\":3}\n".utf8))
        #expect(result.1)
        #expect(result.0.count == 1)
    }
}
