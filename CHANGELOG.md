# Changelog

本專案的功能、可靠性與使用者可見變更都記錄於此。格式依循 Keep a Changelog，版本採 Semantic Versioning。

## [Unreleased]

### Added

- 尚無。

## [0.2.0] - 2026-09-16

### Added

- 為所有 App Server requests 加入 15 秒逾時與 Swift task cancellation。
- 新增 2、4、8、16、30 秒上限的 exponential reconnect backoff，並加入少量 jitter。
- 將未確認的 reset attempt 與 idempotency key 保存於本機，斷線或逾時後重試會沿用同一個 key。
- 新增登入 URL allowlist，只允許 HTTPS 的 OpenAI 與 ChatGPT 網域。
- 新增 App Server malformed JSONL 錯誤狀態，不再靜默忽略。
- 新增 reset retry、backoff 與登入網址安全測試；測試總數增加至 9 項。
- 新增完整架構與維護文件 `docs/ARCHITECTURE.md`。

### Changed

- 將 App Server client 從手動 dispatch queue 與 `@unchecked Sendable` 改為 Swift actor 隔離。
- 用量更新期間收到新通知時，會在目前 refresh 完成後補做一次同步。
- App Server pipe 不存在或 process 已停止時會明確失敗，不再使用 optional write。
- App Server client version 改由 App bundle version 取得，避免版本字串分散。
- 每次打包前清除舊 `.app` bundle，避免殘留過期資源。

### Security

- Reset request 在無法保存 recovery state 時不會送出。
- Reset 結果不確定時保留 recovery state，避免使用新的 key 意外消耗第二個 reset。

## [0.1.0] - 2026-09-16

### Added

- 初始 macOS 14+ menu bar app。
- 顯示 ChatGPT 方案、Codex quota windows、用量百分比與重置倒數。
- App Server event update 與 60 秒 polling。
- 浮動置頂視窗、ChatGPT 登入、Login Item 與 earned reset 兌換。
- 本機 `.app` 打包及 ad-hoc signing script。
