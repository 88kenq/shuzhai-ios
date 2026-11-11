# 書齋 iPhone 版

本機 TXT／EPUB 閱讀器，Android 版「書齋」的 iPhone 版本。

## 下載

每次更新程式後，GitHub 會自動用 Mac 主機編譯，產生 **ShuZhai.ipa**，放在本儲存庫的
[Releases → latest](../../releases/tag/latest)。

## 安裝到 iPhone（用 Windows 電腦＋Sideloadly）

1. 在 Windows 電腦安裝 **iTunes**（Apple 官網下載版，不要用 Microsoft Store 版）與 **Sideloadly**（https://sideloadly.io）。
2. 用 USB 線把 iPhone 接上電腦，iPhone 上按「信任這部電腦」。
3. 打開 Sideloadly，把 `ShuZhai.ipa` 拖進視窗，輸入你的 Apple ID，按 **Start**。
4. 第一次安裝後，在 iPhone 打開 **設定 → 一般 → VPN 與裝置管理**，點你的 Apple ID，按「信任」。
5. iOS 16 以上還要打開 **設定 → 隱私權與安全性 → 開發者模式**，開啟後重新開機。

免費 Apple ID 安裝的 App 會在 **7 天後過期**，到時用 Sideloadly 再裝一次即可（書和進度不會消失）。
Sideloadly 也可以設定在 iPhone 與電腦連同一個 Wi-Fi 時自動續簽。

## 專案結構

- `Sources/ShuZhaiCore`：核心邏輯（編碼偵測、切目錄、繁簡轉換、取代規則、EPUB 解析、書庫），與 Android 版邏輯相同，資料格式互通。可在 Linux／macOS 用 `swift test` 測試。
- `App/Sources`：iPhone 介面（SwiftUI＋CoreText 排版）。
- `project.yml`：XcodeGen 專案設定。
- `.github/workflows/build.yml`：自動編譯無簽章 IPA。

繁簡轉換詞庫來自 [OpenCC](https://github.com/BYVoid/OpenCC)（Apache 2.0）。
