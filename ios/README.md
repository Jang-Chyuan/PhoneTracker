# PhoneTracker iOS

PhoneTracker 的 iOS 版（SwiftUI + CoreLocation + Google Maps SDK for iOS），從 Android 版移植。定位演算法、記錄間隔、資料庫結構與保留規則都與 Android 版相同，並沿用同一組單元測試。

安裝給一般使用者（AltStore／Xcode）請看 [INSTALL.md](INSTALL.md)；與 Android 的並排比較見 [docs/ios-android-comparison](../docs/ios-android-comparison/README.md)。

## 開啟與執行

1. 從 App Store 安裝 **Xcode**（需 iOS 17 以上的 SDK）。安裝後執行一次 `sudo xcode-select -s /Applications/Xcode.app`。
2. 用 Xcode 開啟 `ios/PhoneTracker.xcodeproj`。
3. 在 **PhoneTracker** 與 **PhoneTrackerWidget** 兩個 target 的「Signing & Capabilities」選擇你的 Team（免費 Apple ID 的 Personal Team 也可以）。若出現 bundle identifier 已被使用，把 `com.phonetracker.ios` 改成自己的前綴，例如 `com.你的名字.phonetracker`，widget 改成同一前綴加 `.widget`。
4. 選擇 iPhone 或模擬器並按 Run。第一次裝到實機時，需在 iPhone 開啟「開發者模式」，並在「設定 › 一般 › VPN 與裝置管理」信任開發者。

修改 `project.yml` 後可用 `xcodegen generate` 重新產生專案（`brew install xcodegen`）。第一次建置時 Xcode 會透過 Swift Package Manager 下載 Google Maps SDK。

## Google Maps 設定

與 Android 版一樣使用 Google Maps；金鑰不納入 Git：

1. 在 [Google Cloud Console](https://console.cloud.google.com/google/maps-apis) 啟用 **Maps SDK for iOS**，建立 API 金鑰。
2. 建議將金鑰限制為「iOS 應用程式」，加入 bundle ID `com.phonetracker.ios`（若改了 bundle ID 用新的），API 限制只勾 Maps SDK for iOS。Android 金鑰若限制為 Android 應用程式，iOS 不能共用。
3. 複製 `ios/Secrets.xcconfig.example` 為 `ios/Secrets.xcconfig`，填入 `GOOGLE_MAPS_IOS_API_KEY = 你的金鑰`，重新建置。

沒有金鑰時 App 仍可開啟並記錄 GPS，地圖底圖空白，畫面提示「尚未設定 Google Maps 金鑰；GPS 記錄仍可使用」，與 Android 相同。行動版 Maps SDK 的地圖載入目前不收費，但 Google Cloud 專案仍需綁定帳單帳戶。

## 測試

- Xcode：⌘U 執行 `PhoneTrackerTests`。
- 只有 Command Line Tools 時：`ios/scripts/test-core.sh` 會編譯核心程式與測試並執行，不需要 Xcode。

測試內容逐條移植自 `app/src/test`：精度門檻、三點平滑、高速 90% 權重、異常跳點、靜止鎖定與 3 秒離開、30／5／1 秒記錄間隔、顯示座標有效性、軌跡分段與 4,000 點繪圖額度。另外新增 SQLite 測試，涵蓋顯示座標保存、80,000 筆保留、8,000 筆查詢上限與分頁。

## 與 Android 版一致的部分

- 定位管線：`Core/LocationPipeline.swift`、`MotionDetector.swift`、`LocationAccuracy.swift`、`DisplayLocation.swift`、`LocationPreview.swift`。精度不足的估算位置仍顯示在地圖並標示「估算位置，未寫入軌跡」，超過 30 秒才標示過期，與 Android 融合定位版相同。精度、速度型別都用 `Float`，和 Kotlin 一樣，邊界判斷結果也相同。
- 記錄：每秒檢查一次，速度 ≤ 10 km/h 每 30 秒保存，> 10～20 每 5 秒，> 20 每秒；無新合格定位不補寫。
- 資料庫：`phonetracker.sqlite`，表格與欄位跟 Android 相同。寫入與修剪在同一個交易內，最多保留 80,000 筆。
- 即時地圖：顯示手機位置、精度圈、900 ms 移動動畫，以及「即時位置」恢復跟隨。手動拖動地圖會停止跟隨。地圖上的動畫座標會在仍有效時寫入資料庫。
- 歷史軌跡：最近 1／3／6 小時或指定起訖（最長 240 小時）。分段規則、每 10 秒自動重新整理、回放每秒前進一分鐘、時間滑桿、「完整軌跡」，以及長按可拖動的橘色三角形標定時間，都與 Android 相同。
- 匯出地圖：PNG 圖片，地圖下方附查詢資訊與標定時間，可選「儲存圖片」（存到「檔案」）或「分享圖片」（分享選單，也可以存到「照片」）。暫存檔超過 7 天會自動清除。
- 權限：需要精確位置，只有概略位置時不會開始記錄。

## iOS 平台差異

| Android | iOS |
| --- | --- |
| Google Maps（Android 金鑰） | Google Maps（另需一把 iOS 金鑰，見上方） |
| 前景服務通知與「停止記錄」 | 鎖定畫面／動態島 Live Activity，有「停止記錄」按鈕，點一下會開啟 App；狀態列也會顯示藍色定位指示 |
| 「背景執行」按鈕 | iOS 不允許 App 自己關閉，直接回到主畫面即可，記錄會繼續 |
| 從最近使用畫面移除後繼續記錄 | **iOS 無法保證**。使用者在多工畫面把 App 滑掉後，系統會停止精確 GPS。若定位權限設為「永遠」，系統偵測到明顯移動（約數百公尺）時會在背景重新啟動 App 並自動恢復記錄，中間會有空檔 |
| WakeLock | 不需要；背景定位模式會讓 App 持續執行 |
| 重新開機後，開啟 App 才恢復 | 相同；若權限為「永遠」，也可能由系統的位置事件喚醒後恢復 |

Android 的「記錄清單」頁在 Android 版裡沒有入口可以進去，所以 iOS 版沒有做這個畫面。資料庫的分頁查詢（`page`）仍保留，並有測試涵蓋。

## 模擬器驗收結果（iOS 27 模擬器，iPhone 18 Pro）

- 單元測試 23 項全部通過（Xcode 與 `scripts/test-core.sh`）。
- 權限：拒絕時顯示說明並可開啟設定；首次允許後自動開始記錄，接著詢問「永遠」。
- 記錄間隔（直接讀資料庫核對）：72 km/h 約每 1 秒、14.4 km/h 約每 5 秒、0.7 km/h 每 30 秒；螢幕開著時保存地圖動畫座標，背景時保存管線座標。
- 回主畫面與鎖屏時持續記錄；鎖定畫面與動態島顯示記錄卡片，「停止記錄」可停止且重開 App 後維持停止。
- 歷史：1／3／6 小時、指定起訖、回放、完整軌跡、長按拖動三角形並吸附到軌跡、匯出 PNG（儲存到檔案與分享）。
- 即時：跟隨移動、手動拖地圖後停止跟隨、按「即時位置」恢復；位置過期時顯示提示且標記變淡。

以上在 MapKit 版本完成；改用 Google Maps 後已在模擬器重新驗證記錄、停止、歷史軌跡、拖動三角形（Google 原生長按拖動）與匯出。

模擬器的固定位置只會送出一次定位（實機靜止時仍會持續回報），因此測 30 秒間隔要用極慢速路線。

## 實機驗收

與 Android 版相同：允許精確位置 → 確認即時位置與記錄筆數 → 回主畫面／鎖屏後等待並返回 → 歷史選擇時段／回放／拖動三角形 → 從鎖定畫面「停止記錄」確認筆數不再增加 → 重開 App 確認停止狀態保留。拒絕權限、只給概略位置、關閉定位服務、沒有歷史資料時應顯示說明。模擬器可用 Xcode 的 Debug › Simulate Location（例如 City Run、Freeway Drive）測試移動與記錄間隔。
