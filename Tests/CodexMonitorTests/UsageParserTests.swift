import Foundation
import Testing
@testable import CodexMonitor

struct UsageParserTests {
    @Test func parsesAccountAndMultiWindowUsage() throws {
        let account = try UsageParser.account(from: [
            "account": ["type": "chatgpt", "email": "user@example.com", "planType": "pro"]
        ])
        #expect(account?.planLabel == "Pro")

        let now = Date(timeIntervalSince1970: 100)
        let usage = try UsageParser.usage(from: [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "credits": ["hasCredits": true, "unlimited": false, "balance": "12.50"],
                    "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_000],
                    "secondary": ["usedPercent": 40.5, "windowDurationMins": 10_080, "resetsAt": 2_000]
                ]
            ],
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [[
                    "id": "reset-1",
                    "resetType": "codexRateLimits",
                    "status": "available",
                    "grantedAt": 50,
                    "expiresAt": 3_000,
                    "title": "Full reset"
                ]]
            ]
        ], now: now)

        #expect(usage.windows.count == 2)
        #expect(usage.windows[0].durationLabel == "5 小時用量")
        #expect(usage.windows[1].durationLabel == "1 週用量")
        #expect(usage.windows[1].usedPercent == 40.5)
        #expect(usage.availableResetCount == 1)
        #expect(usage.resetCredits.first?.id == "reset-1")
        #expect(usage.credits?.balance == "12.50")
        #expect(usage.fetchedAt == now)
    }

    @Test func fallsBackToLegacyRateLimitAndClampsPercentage() throws {
        let usage = try UsageParser.usage(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 125, "windowDurationMins": 60, "resetsAt": 1_000]
            ]
        ])
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedPercent == 100)
        #expect(usage.windows[0].remainingPercent == 0)
    }

    @Test func missingAccountMeansSignedOut() throws {
        #expect(try UsageParser.account(from: ["account": NSNull()]) == nil)
    }

    @Test func ignoresMalformedWindowsWithoutCrashing() throws {
        let usage = try UsageParser.usage(from: [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 20]]
        ])
        #expect(usage.windows.isEmpty)
    }
}
