# PhoneTracker iOS 安裝說明

PhoneTracker 沒有上架 App Store。下面兩種方式擇一：

- **方式 A：收到 `PhoneTracker.ipa`**（不需要 Xcode）→ 用 AltStore 安裝。
- **方式 B：自己有原始碼與 Xcode** → 從 Xcode 直接裝到手機。

兩種方式都只需要**免費的 Apple ID**，但 App 的簽章每 **7 天**到期，需要重新整理（AltStore 可在背景自動完成）。

需求：iPhone，iOS 17 以上；一台 Mac（macOS 11 以上）或 Windows 電腦。

---

## 方式 A：用 AltStore 安裝 ipa

### 1. 在電腦安裝 AltServer

1. 到 [altstore.io](https://altstore.io) 下載 **AltStore Classic** 的 AltServer（macOS 或 Windows）。
2. macOS：把 `AltServer.app` 拖到「應用程式」資料夾，打開後選單列會出現 AltServer 圖示。

### 2. 把 AltStore 裝到 iPhone

1. 用傳輸線把 iPhone 接到電腦，解鎖手機；若跳出「要信任這部電腦嗎？」選「信任」。
2. macOS：在 Finder 左側點你的 iPhone，勾選「**連接 Wi-Fi 時顯示此 iPhone**」，按「套用」。
3. 點選單列的 AltServer 圖示 →「**Install AltStore**」→ 選你的 iPhone。
4. 輸入 **你自己的** Apple ID 與密碼（只會傳給 Apple，用來簽章）。
5. 等待出現安裝成功的通知。

### 3. 在 iPhone 上允許執行

1. **設定 › 一般 › VPN 與裝置管理** → 點你的 Apple ID →「信任」。
2. **設定 › 隱私權與安全性 › 開發者模式** → 開啟，手機會重新開機，開機後再確認一次「開啟」。

### 4. 安裝 PhoneTracker

1. 把 `PhoneTracker.ipa` 傳到 iPhone（AirDrop、存到「檔案」App 都可以）。
2. 打開 AltStore →「My Apps」→ 左上角「**+**」→ 選 `PhoneTracker.ipa`。
3. 若 AltStore 詢問 App 擴充功能（app extensions）：PhoneTracker 內含一個鎖定畫面元件。建議保留；若因免費帳號的 App 數量上限必須移除，App 仍可正常記錄，只是鎖定畫面不會顯示「停止記錄」卡片。

免費 Apple ID 最多同時啟用 3 個自行安裝的 App（AltStore 本身算 1 個），7 天內最多註冊 10 個 App ID。

### 5. 每 7 天重新整理

- 只要 iPhone 和開著 AltServer 的電腦在**同一個 Wi-Fi**，AltStore 會在背景自動重新整理。
- 也可以手動：打開 AltStore →「My Apps」→ 點 PhoneTracker 旁的天數（例如「7 DAYS」）。
- 若已經過期（App 打不開），照上面手動重新整理即可。**資料不會遺失**。

> 另一個選擇是 [SideStore](https://docs.sidestore.io)：裝好後不需要電腦就能重新整理，但第一次設定步驟較多，請照官方說明操作。

---

## 方式 B：用 Xcode 安裝（開發者）

1. 安裝 Xcode，執行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
2. 依 [`ios/README.md`](README.md) 設定 Google Maps 金鑰（`ios/Secrets.xcconfig`）。
3. 打開 `ios/PhoneTracker.xcodeproj`，在 PhoneTracker 與 PhoneTrackerWidget 兩個 target 的「Signing & Capabilities」選你的 Team。
4. 接上 iPhone，選擇手機後按 Run。第一次需在手機開啟開發者模式並信任開發者（同方式 A 的步驟 3）。
5. 7 天後簽章到期：接上 Mac 再按一次 Run，資料會保留。

若 Xcode 顯示 bundle identifier 已被使用，把 `com.phonetracker.ios` 改成自己的前綴（widget 用同一前綴加 `.widget`），並記得同步修改 Google Cloud 上金鑰的 iOS bundle ID 限制，否則地圖會是空白。

---

## 第一次開啟 App

1. **位置權限**：選「使用 App 期間允許」，並確認「精確位置」是開啟的（只有概略位置無法記錄）。
2. 接著會詢問是否「**改為永遠允許**」：建議選「改為永遠允許」，iOS 結束 App 後才能自動恢復記錄。
3. 第一次鎖屏時，鎖定畫面會詢問「要允許來自 PhoneTracker 的即時動態嗎？」→ 選「**允許**」，鎖定畫面才會顯示記錄卡片和「停止記錄」按鈕。

## 使用注意

- 記錄中直接回主畫面或鎖屏即可，記錄會持續；狀態列會出現藍色定位圖示。
- 在多工畫面把 App **滑掉**，iOS 會停止精確 GPS。要停止請按「停止記錄」，不要用滑掉的方式。
- 所有位置資料只存在這支手機上，不會上傳。
