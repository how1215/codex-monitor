import Foundation

enum MonitorPhase: Equatable {
    case loading
    case ready
    case stale
    case signedOut
    case cliMissing
    case offline

    var label: String {
        switch self {
        case .loading: "連線中"
        case .ready: "即時"
        case .stale: "資料可能已過期"
        case .signedOut: "尚未登入"
        case .cliMissing: "找不到 Codex CLI"
        case .offline: "無法連線"
        }
    }
}

struct AccountStatus: Equatable {
    let authType: String
    let email: String?
    let planType: String?

    var planLabel: String {
        guard let planType, !planType.isEmpty else { return "未知方案" }
        return planType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct RateLimitWindow: Identifiable, Equatable {
    let id: String
    let limitID: String
    let limitName: String?
    let kind: String
    let usedPercent: Double
    let windowDurationMinutes: Int
    let resetsAt: Date

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    var title: String {
        if let limitName, !limitName.isEmpty, limitName != limitID {
            return "\(limitName) · \(durationLabel)"
        }
        return durationLabel
    }

    var durationLabel: String {
        if windowDurationMinutes % 10_080 == 0 {
            return "\(windowDurationMinutes / 10_080) 週用量"
        }
        if windowDurationMinutes % 1_440 == 0 {
            return "\(windowDurationMinutes / 1_440) 天用量"
        }
        if windowDurationMinutes % 60 == 0 {
            return "\(windowDurationMinutes / 60) 小時用量"
        }
        return "\(windowDurationMinutes) 分鐘用量"
    }
}

struct ResetCredit: Identifiable, Equatable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?
}

struct CreditBalance: Equatable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct UsageSnapshot: Equatable {
    let windows: [RateLimitWindow]
    let resetCredits: [ResetCredit]
    let availableResetCount: Int
    let credits: CreditBalance?
    let fetchedAt: Date

    var nextReset: Date? { windows.map(\.resetsAt).min() }
    var primaryUsedPercent: Double? { windows.first?.usedPercent }
}

enum ResetOutcome: String, Equatable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
}

enum CodexMonitorError: LocalizedError, Equatable {
    case cliNotFound
    case processLaunch(String)
    case disconnected
    case requestTimedOut(String)
    case invalidResponse(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "找不到 Codex CLI。請先安裝 Codex，或確認 codex 位於常用的執行路徑。"
        case .processLaunch(let message):
            "無法啟動 Codex App Server：\(message)"
        case .disconnected:
            "Codex App Server 已中斷。"
        case .requestTimedOut(let method):
            "Codex request 逾時（\(method)）。"
        case .invalidResponse(let message):
            "Codex 回傳了無法辨識的資料：\(message)"
        case .server(let message):
            message
        }
    }
}

enum UsageParser {
    static func account(from result: [String: Any]) throws -> AccountStatus? {
        guard let raw = result["account"], !(raw is NSNull) else { return nil }
        guard let account = raw as? [String: Any], let type = account["type"] as? String else {
            throw CodexMonitorError.invalidResponse("缺少 account.type")
        }
        return AccountStatus(
            authType: type,
            email: account["email"] as? String,
            planType: account["planType"] as? String
        )
    }

    static func usage(from result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        var buckets: [[String: Any]] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            buckets = byID.keys.sorted().compactMap { byID[$0] as? [String: Any] }
        } else if let single = result["rateLimits"] as? [String: Any] {
            buckets = [single]
        }

        var windows: [RateLimitWindow] = []
        for bucket in buckets {
            let limitID = bucket["limitId"] as? String ?? "codex"
            let limitName = bucket["limitName"] as? String
            for kind in ["primary", "secondary"] {
                guard let window = bucket[kind] as? [String: Any] else { continue }
                guard
                    let usedPercent = number(window["usedPercent"]),
                    let duration = integer(window["windowDurationMins"]),
                    let resetTimestamp = number(window["resetsAt"])
                else { continue }
                windows.append(RateLimitWindow(
                    id: "\(limitID)-\(kind)",
                    limitID: limitID,
                    limitName: limitName,
                    kind: kind,
                    usedPercent: min(max(usedPercent, 0), 100),
                    windowDurationMinutes: duration,
                    resetsAt: Date(timeIntervalSince1970: resetTimestamp)
                ))
            }
        }
        windows.sort {
            if $0.windowDurationMinutes == $1.windowDurationMinutes { return $0.id < $1.id }
            return $0.windowDurationMinutes < $1.windowDurationMinutes
        }

        let resetContainer = result["rateLimitResetCredits"] as? [String: Any]
        let availableCount = integer(resetContainer?["availableCount"]) ?? 0
        let resetCredits = (resetContainer?["credits"] as? [[String: Any]] ?? []).compactMap { item -> ResetCredit? in
            guard let id = item["id"] as? String else { return nil }
            return ResetCredit(
                id: id,
                resetType: item["resetType"] as? String ?? "unknown",
                status: item["status"] as? String ?? "unknown",
                grantedAt: date(item["grantedAt"]),
                expiresAt: date(item["expiresAt"]),
                title: item["title"] as? String,
                description: item["description"] as? String
            )
        }

        let creditsObject = (result["credits"] as? [String: Any])
            ?? buckets.compactMap { $0["credits"] as? [String: Any] }.first
        let credits = creditsObject.map {
            CreditBalance(
                hasCredits: $0["hasCredits"] as? Bool,
                unlimited: $0["unlimited"] as? Bool,
                balance: string($0["balance"])
            )
        }

        return UsageSnapshot(
            windows: windows,
            resetCredits: resetCredits,
            availableResetCount: availableCount,
            credits: credits,
            fetchedAt: now
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        number(value).map(Date.init(timeIntervalSince1970:))
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }
}
