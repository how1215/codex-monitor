# Codex Usage Monitor for macOS

> **Platform:** macOS 14 Sonoma or later. This application is built specifically for Mac and does not support Windows or Linux.

一個原生 macOS 選單列工具，用來近即時顯示 Codex 訂閱方案、用量比例與重置倒數。它透過官方 Codex App Server 讀取資料，不擷取畫面，也不直接讀取或保存登入 token。

## 功能

- 選單列即時顯示主要用量百分比
- 顯示所有官方回傳的 quota windows、剩餘比例與每秒更新的重置倒數
- 收到用量事件時立即更新，並每 60 秒重新同步
- 可開啟永遠置頂的浮動視窗
- earned reset 可用時，經二次確認後兌換
- 支援 ChatGPT 瀏覽器登入及登入後自動啟動
- CLI 缺失、未登入、離線及 stale 資料狀態

## 需求

- macOS 14 或更新版本
- 已安裝 Codex CLI
- 使用 ChatGPT 帳號登入 Codex；API key 模式不提供訂閱 quota 資料
- 建議安裝完整 Xcode 以產生與封裝 `.app`

目前環境只有 Apple Command Line Tools 時，仍可建置及執行 Swift Package，但無法完成正式簽章／公證。

## 開發與執行

```sh
swift test
swift run CodexMonitor
```

產生可雙擊的本機 `.app`：

```sh
./scripts/build-app.sh
open ".build/Codex Monitor.app"
```

此腳本使用 ad-hoc 簽章，只適合本機或少量測試。公開發布前仍需 Apple Developer ID 簽章與公證。

## 專案文件

- [程式架構與安全設計](docs/ARCHITECTURE.md)
- [版本變更紀錄](CHANGELOG.md)

第一次執行若尚未登入，可在程式內按「登入 ChatGPT」。程式會啟動官方瀏覽器登入流程。

## 資料更新方式

使用量由 `account/rateLimits/read` 取得，並監聽 `account/rateLimits/updated`。倒數使用官方 `resetsAt` Unix timestamp 在本機每秒更新。程式不以 token 數自行推算訂閱餘額，因此數值可能受到官方後端統計延遲影響。

## Reset 安全性

「使用 Reset」只會呼叫官方 `account/rateLimitResetCredit/consume`，而且只有帳號回傳可用 earned reset 時才能操作。它不能任意清零用量，也不會購買付費 instant reset。自動化測試不會呼叫真實 reset endpoint。

## 隱私

所有通訊都由本機 Codex App Server 處理。程式不收集遙測、不輸出 token，也不將帳號或用量傳送到其他服務。

協定參考：[OpenAI Codex App Server documentation](https://developers.openai.com/codex/app-server)
