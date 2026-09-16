# Codex Usage Monitor Architecture

## 目的與邊界

Codex Usage Monitor 是 macOS 14+ 原生 menu bar app。它透過使用者本機已安裝的 Codex CLI 啟動官方 App Server，以 stdio JSONL 讀取 ChatGPT 帳號與 Codex quota 資料。

程式不讀取或保存 access token、不自行推算訂閱額度、不提供任意清零，也不處理付費 reset 結帳。

## 元件

| 元件 | 責任 |
| --- | --- |
| `CodexMonitorApp` | 建立 menu bar scene、共享 monitor 與浮動視窗。 |
| `UsageMonitor` | 管理 UI state、60 秒 polling、事件合併、重連與 reset workflow。 |
| `CodexAppServerClient` | Actor-isolated process、JSON-RPC correlation、timeout、取消與 server events。 |
| `UsageParser` | 將 App Server response 轉換成 account、quota、credits 與 reset models。 |
| `ResetAttemptStore` | 在 UserDefaults 保存未確認 reset 的 opaque ID 與 idempotency key。 |
| `MonitorView` | 顯示方案、用量視窗、倒數、狀態、reset 與設定操作。 |
| `FloatingPanelController` | 管理跨 Spaces 的 always-on-top `NSPanel`。 |

## 資料流

1. App 啟動後搜尋可信的本機 `codex` executable 路徑。
2. Client 啟動 `codex app-server --listen stdio://`。
3. Client 依序送出 `initialize` 與 `initialized`。
4. Monitor 呼叫 `account/read`，再以 `account/rateLimits/read` 取得完整 snapshot。
5. `account/rateLimits/updated`、`account/updated` 或 login completion 事件會觸發重新讀取完整 snapshot。
6. 沒有事件時每 60 秒同步一次；重置倒數則由 UI 使用官方 `resetsAt` 在本機更新。

事件發生在既有 refresh 期間時，Monitor 會記錄 pending refresh，於目前同步結束後再執行一次，避免漏掉最新狀態。

## 可靠性設計

### Request lifecycle

- 每個 JSON-RPC request 都有唯一整數 ID。
- 每個 request 最長等待 15 秒；逾時會移除 continuation 並回報 `requestTimedOut`。
- 呼叫端取消 Swift task 時，對應 pending request 會被清除。
- Process 結束時，所有 pending requests 會一起失敗，不留下懸掛 continuation。
- Pipe 或 process 不可用時，write 必須直接失敗。

### Reconnect

- 非 CLI-missing 錯誤採 exponential backoff：2、4、8、16、30 秒，之後維持 30 秒。
- 每次 delay 加入最多 0.5 秒 jitter，避免多個 instance 同時重連。
- 連線成功後 attempt counter 歸零。
- 使用者按「重新偵測」會立即清除 backoff 並重試。

### Reset transaction

Reset 是可能消耗帳號權益的操作，必須遵守下列不變條件：

1. 送出前先將 `idempotencyKey`、可選的 `creditID` 與開始時間保存至 UserDefaults。
2. 若保存失敗，禁止送出 reset request。
3. 若 request 逾時或斷線，不清除 pending attempt。
4. 使用者再次操作時必須重用相同 key，讓官方回傳 `alreadyRedeemed` 或完成原嘗試。
5. 收到 `reset`、`alreadyRedeemed`、`nothingToReset` 或 `noCredit` 後才清除 pending attempt。
6. 成功後重新讀取 rate limits，不自行推測新的額度與 reset time。

## 安全與隱私

- 不直接存取 Codex authentication files。
- 不記錄 token、email、完整 server payload 或 auth URL。
- 瀏覽器登入 URL 必須是 HTTPS，且 host 為 `openai.com`、`chatgpt.com` 或其子網域。
- App Server stderr 不寫入一般 log，避免第三方測試版意外洩漏環境資訊。
- Reset store 僅包含官方 opaque reset ID、UUID idempotency key 與時間戳。

## UI 狀態

| State | 意義 |
| --- | --- |
| `loading` | 正在啟動或首次同步。 |
| `ready` | 最近一次完整同步成功。 |
| `stale` | 保留舊 snapshot，但目前同步或連線失敗。 |
| `signedOut` | App Server 沒有 ChatGPT account。 |
| `cliMissing` | 找不到可執行的 Codex CLI。 |
| `offline` | 沒有可顯示的 snapshot，且連線失敗。 |

## 測試與打包

- Parser tests 覆蓋 multi-window、legacy response、缺少帳號與 malformed window。
- Monitor tests 覆蓋 reset eligibility、持久化 idempotency retry、登入 URL allowlist 與 reconnect backoff。
- 自動測試不得呼叫真實 reset endpoint。
- `scripts/build-app.sh` 會建立 release binary、重建 app bundle 並使用 ad-hoc signature；正式發布仍需要 Developer ID 與 notarization。

## 維護規則

- 每次功能、行為、可靠性、安全或發布流程變更，都要先加入 `CHANGELOG.md` 的 `Unreleased`。
- App Server 新欄位先以 backward-compatible parser 處理，再補 fixture test。
- 任何可能消耗 reset 的改動，都必須包含失敗、逾時和 retry 測試。
- 不在 log、crash message、analytics 或測試 fixture 中保存真實帳號資料。
