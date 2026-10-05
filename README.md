# PhoneTracker

獨立 Android 手機位置記錄 App，套件名稱 `com.phonetracker`。功能源自 DogTracker 的手機定位管線，使用 Kotlin 與 Android 原生介面；資料庫、服務與 App 身分獨立，可與 DogTracker 並存。

## 功能

- 即時 Google 地圖：手機位置、估計精度範圍、跟隨位置及手動平移／縮放。
- 手機 GPS 前景服务記錄，通知提供「停止記錄」，離開 App 畫面後可繼續。停止偏好跨重啟保留。
- 歷史軌跡：最近 1／3／6／12／24 小時或自訂起訖（最多 240 小時），使用手機本地時區。
- 歷史回放：播放／暫停、拖曳時間滑桿、返回完整軌跡；每秒前進一分鐘，以實際資料起訖為準。
- 位置記錄：SQLite 每頁 50 筆，可往前翻頁，顯示時間、座標、精度、速度與移動狀態。

GPS 約每秒取得新樣本，沿用 DogTracker 的精度檢查、三點平滑、高速最新點 90% 權重、異常跳點拒收與靜止鎖定。依原始速度 ≤ 10 km/h 每 5 秒保存，> 10 且 ≤ 20 每 3 秒，> 20 每秒；無新合格定位不補寫。保留原始、平滑與地圖動畫座標，最多保存 80,000 筆，寫入與修剪使用同一交易。

歷史優先使用保存的地圖顯示座標。不同記錄 session、超過兩分鐘中斷、日期變更線或無效座標會分段。每次查詢最近 8,000 筆，畫面最多 4,000 點／120 段，超量時提示；繪圖限制不刪除資料庫記錄。

此專案僅保存手機本機位置，沒有 BLE、Master／Slave、雲端同步、帳號與 ML 功能。DogTracker 的既有位置資料不會自動複製到本 App。

## 開啟與建置

Android Studio 開啟本目錄。使用 JDK 17、Gradle wrapper 9.4.1、Android SDK 37（target 36）。Windows 可執行：

```powershell
$env:JAVA_HOME = 'C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot'
$env:GRADLE_USER_HOME = 'C:/Users/jjchy/.gradle'
.\gradlew.bat testDebugUnitTest assembleRelease
```

APK：`app/build/outputs/apk/release/app-release.apk`。本機已有供開發測試用的 `app/debug.keystore`，不納入 Git；release 暫使用同一開發簽章，正式發佈前應設定正式 signingConfig。

可安裝至連接的手機：

```powershell
adb install -r app/build/outputs/apk/release/app-release.apk
adb shell am start -n com.phonetracker/.MainActivity
```

## Google Maps 設定

`local.properties` 不納入 Git，內容為 Android SDK 路徑及 Google Maps Android API Key：

```properties
sdk.dir=C\:/Users/jjchy/AppData/Local/Android/Sdk
GOOGLE_MAPS_ANDROID_API_KEY=YOUR_ANDROID_MAPS_KEY
```

也可透過環境變數 `GOOGLE_MAPS_ANDROID_API_KEY` 提供金鑰。本機初始化沿用 DogTracker 的本機 Maps 設定；若金鑰限制 Android App，需在 Google Cloud Console 加入 **`com.phonetracker` 與本 App 簽章 SHA-1**，並啟用 Maps SDK for Android。取得簽章：

```powershell
.\gradlew.bat signingReport
```

本機開發簽章 SHA-1：`5E:8F:16:06:2E:A3:CD:2C:4A:0D:54:78:76:BA:A6:F3:8C:AB:F6:25`。

地圖底圖需要網路及可使用的 Maps 金鑰；GPS 與本機記錄可離線使用。API 設定見 [Google Maps 文件](https://developers.google.com/maps/documentation/android-sdk/start)。

## 權限與驗收

第一次開啟要求精確位置；Android 13+ 顯示通知權限請求。需要開啟 GPS，僅概略位置不啟動記錄。服務只從前景啟動。使用者強制停止或手機重開機後，下次開啟 App 且記錄偏好仍啟用時恢復；不會自行在開機後啟動。

實機驗收：允許精確位置 → 確認即時位置與記錄筆數 → 回桌面／鎖屏後等待並返回 → 歷史選擇時段／回放 → 停止記錄確認筆數不再增加 → 重開 App 確認停止狀態保留。拒絕權限、關 GPS、沒有歷史資料時應顯示說明。

## 程式位置

| 檔案 | 責任 |
| --- | --- |
| `MainActivity.kt` | 即時地圖、歷史時間選擇、回放、記錄清單與權限流程 |
| `HistoryGeometry.kt` | 軌跡分段與繪圖額度 |
| `location/LocationTrackerService.kt` | GPS 前景服務、通知、每秒處理與記錄 |
| `location/LocationTrackerStore.kt` | 獨立 SQLite、交易保存、80,000 筆保留與歷史查詢 |
| `location/LocationPipeline.kt` | 樣本接受、平滑、記錄間隔 |
| `location/MotionDetector.kt` | 移動／靜止判定 |
| `app/src/test` | 沿用定位管線測試與新增歷史幾何測試 |
