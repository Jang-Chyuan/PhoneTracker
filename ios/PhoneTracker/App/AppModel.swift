import CoreLocation
import SwiftUI
import UIKit

/// Port of the Android MainActivity: live map, history range, playback and export.
@MainActor
final class AppModel: ObservableObject {
  enum Mode: String { case live, history }

  @Published private(set) var mode: Mode = .live
  @Published private(set) var statusText = "等待定位"
  @Published private(set) var detailText = "允許精確定位並開啟 GPS 後開始記錄"
  @Published private(set) var recording = false
  @Published private(set) var playbackLabel = "尚無歷史資料"
  @Published private(set) var playing = false
  @Published private(set) var playEnabled = false
  @Published private(set) var sliderProgress = 1000.0
  @Published private(set) var hours: Int64 = 6
  @Published private(set) var customStart: Int64?
  @Published private(set) var customEnd: Int64?
  @Published private(set) var canGoBack = false
  @Published var toast: String?
  @Published var gpsAlert = false
  @Published var settingsAlert: String?
  @Published var showRangePicker = false
  @Published var exportFile: URL?
  @Published var showExportOptions = false
  @Published var showSave = false

  let map = MapController()
  let tracker = LocationTracker.shared
  private let worker = DispatchQueue(label: "PhoneTrackerHistory")
  private var timer: Timer?
  private var navigationStack: [Mode] = []
  private var following = true
  private var active = false
  private var queryVersion = 0
  private var history: [TrackPoint] = []
  private var historyTotal: Int64 = 0
  private var historyTruncated = false
  private var selectedTime: Int64?
  private var fitHistory = true
  private var lastQueryAt: Int64 = 0
  private var historyLoading = false
  private var cursorPoint: TrackPoint?
  private var cursorDragging = false
  private var cursorPoints: [TrackPoint] = []
  private var positionTimestamp: Int64 = 0
  private var positionWasEligible = false
  private var requestStart = false
  private var exporting = false
  private var toastTask: Task<Void, Never>?

  private let format: DateFormatter = {
    let format = DateFormatter(); format.locale = Locale(identifier: "zh_TW"); format.dateFormat = "MM/dd HH:mm:ss"; return format
  }()
  private let timeFormat: DateFormatter = {
    let format = DateFormatter(); format.locale = Locale(identifier: "zh_TW"); format.dateFormat = "HH:mm:ss"; return format
  }()

  init() {
    map.onUserGesture = { [weak self] in self?.following = false }
    map.onAnnotationTap = { [weak self] _ in
      guard let self, let point = cursorPoint else { return }
      playbackLabel = "標定時間 \(cursorTime(point))"
    }
    map.onCursorDragStart = { [weak self] in
      guard let self else { return }
      cursorDragging = true; playing = false
    }
    map.onCursorDrag = { [weak self] coordinate, finished in self?.snapHistoryCursor(coordinate, finished: finished) }
    tracker.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
    switchMode(.live)
  }

  private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
  private func date(_ millis: Int64) -> String { format.string(from: Date(timeIntervalSince1970: Double(millis) / 1000)) }
  private func cursorTime(_ point: TrackPoint) -> String { timeFormat.string(from: Date(timeIntervalSince1970: Double(point.time) / 1000)) }

  func show(_ message: String) {
    toast = message
    toastTask?.cancel()
    toastTask = Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if !Task.isCancelled { toast = nil } }
  }

  // MARK: Lifecycle (onResume / onPause)

  func setActive(_ value: Bool) {
    guard value != active else { return }
    active = value
    if value {
      ensureLocation(manual: false)
      timer?.invalidate()
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
      tick()
    } else {
      playing = false; map.cancelAnimation(); tracker.displayLocation = nil
      timer?.invalidate(); timer = nil
    }
  }

  private func tick() {
    guard active else { return }
    updateLive()
    if mode == .history {
      if playing, let first = history.first, let last = history.last {
        let next = (selectedTime ?? first.time) + 60_000
        selectedTime = min(next, last.time)
        if next >= last.time { playing = false }
        drawHistory()
      } else if selectedTime == nil && !cursorDragging && !historyLoading && now() - lastQueryAt > 10_000 { loadHistory() }
    }
  }

  // MARK: Navigation

  func selectTab(_ id: Mode) {
    if id == .live { following = true; positionTimestamp = 0 }
    if id != mode { navigationStack.append(mode); switchMode(id) }
    else if id == .live { updateLive() }
  }

  func navigateBack() {
    if let previous = navigationStack.popLast() { switchMode(previous) }
    else if mode != .live { switchMode(.live) }
  }

  private func switchMode(_ next: Mode) {
    queryVersion += 1; historyLoading = false; mode = next; playing = false; selectedTime = nil
    canGoBack = !navigationStack.isEmpty || mode != .live
    map.cancelAnimation()
    cursorPoint = nil; cursorDragging = false; cursorPoints = []
    map.clear()
    map.isHistory = mode == .history
    lastQueryAt = 0
    if mode == .history { fitHistory = true; loadHistory() }
    else { positionTimestamp = 0; updateLive() }
  }

  // MARK: Recording

  func toggleRecording() {
    if tracker.running {
      tracker.stop()
      updateLive()
    } else { ensureLocation(manual: true) }
  }

  private func ensureLocation(manual: Bool) {
    if !active || tracker.running || (!manual && !tracker.enabled) { return }
    // The automatic start waits for authorizationChanged(); acting earlier would show a needless prompt.
    if !tracker.authorizationResolved { return }
    let manager = tracker.manager
    switch manager.authorizationStatus {
    case .notDetermined:
      if manual || !tracker.preferences.bool(forKey: "asked_permission") {
        requestStart = true
        tracker.preferences.set(true, forKey: "asked_permission")
        manager.requestWhenInUseAuthorization()
      }
      return
    case .denied, .restricted:
      if manual { settingsAlert = "請在設定中允許 PhoneTracker 使用「精確位置」，僅概略位置無法記錄。" }
      return
    default: break
    }
    if manager.accuracyAuthorization != .fullAccuracy {
      if manual {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseTracking") { [weak self] _ in
          Task { @MainActor in
            guard let self else { return }
            if self.tracker.manager.accuracyAuthorization == .fullAccuracy { self.ensureLocation(manual: true) }
            else { self.show("請允許精確位置，僅概略位置無法記錄") }
          }
        }
      }
      return
    }
    if !CLLocationManager.locationServicesEnabled() {
      if manual { gpsAlert = true }
      return
    }
    if manual { tracker.enabled = true }
    if let error = tracker.start() { show("無法開始記錄：\(error)") }
    // Ask once for "Always" so iOS can relaunch recording after it ends the app; "While Using" still records in the background.
    if manager.authorizationStatus == .authorizedWhenInUse && !tracker.preferences.bool(forKey: "asked_always") {
      tracker.preferences.set(true, forKey: "asked_always")
      manager.requestAlwaysAuthorization()
    }
    updateLive()
  }

  private func authorizationChanged() {
    let status = tracker.manager.authorizationStatus
    if status == .authorizedAlways && tracker.running { tracker.manager.startMonitoringSignificantLocationChanges() }
    guard requestStart else { ensureLocation(manual: false); return }
    guard status != .notDetermined else { return }
    requestStart = false
    if status == .authorizedWhenInUse || status == .authorizedAlways { ensureLocation(manual: true) }
    else { show("請允許精確位置，僅概略位置無法記錄") }
  }

  // MARK: Live

  private func updateLive() {
    let live = tracker.live
    recording = live.running
    statusText = (live.running ? "● 記錄中 · " : "○ ") + live.status
    guard mode == .live else { return }
    guard let position = live.position else {
      positionWasEligible = false
      detailText = !live.running ? "即時位置尚未啟動，請按「開始記錄」取得手機位置"
        : !GoogleMapsKey.configured ? "尚未設定 Google Maps 金鑰；GPS 記錄仍可使用"
        : "等待融合定位 · 軌跡精度需 ≤ 30 m，高速需 < 50 m"
      return
    }
    let age = live.ageSeconds ?? .infinity
    let recordingEligible = position.recordingEligible
    if !recordingEligible { tracker.displayLocation = nil }
    let speed = position.speedKmh.map { String(format: "%.1f km/h", $0) } ?? "速度未知"
    detailText = "\(date(position.timestamp)) · 精度 \(Int(position.accuracy)) m · \(speed)" +
      "\n已保存 \(live.saved) 筆 · 間隔 \(live.intervalSeconds) 秒" +
      (recordingEligible ? " · 合格定位" : " · 估算位置，未寫入軌跡") + (age > 30 ? " · 最後位置已過期" : "")
    let target = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
    map.updateLiveMarker(target: target, title: "手機位置", snippet: "\(date(position.timestamp)) · 精度 \(Int(position.accuracy)) m", stale: age > 30)
    let stamp = position.timestamp
    if stamp != positionTimestamp {
      positionTimestamp = stamp
      let session = live.sessionId
      // An indoor estimate must not enter saved coordinates through map animation.
      let jump = !(recordingEligible && positionWasEligible)
      positionWasEligible = recordingEligible
      map.animateMarker(to: target, jump: jump) { [weak self] coordinate in
        guard let self, self.active, age <= 3, recordingEligible else { return }
        self.tracker.displayLocation = DisplayLocation(session: session, fixTime: stamp, latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude, receivedNanos: monotonicNanos())
      }
      map.setAccuracyCircle(center: target, radius: Double(position.accuracy))
      if following && age <= 30 { map.move(to: target, zoom: map.zoom < 14 ? 17 : map.zoom, animated: true) }
    }
  }

  // MARK: History

  var rangeTitle: String { customStart == nil ? "\(hours) 小時" : "指定起訖" }

  func selectRange(_ duration: Int64) {
    hours = duration; customStart = nil; customEnd = nil; selectedTime = nil; playing = false
    cursorPoint = nil
    fitHistory = true; loadHistory()
  }

  func applyCustomRange(start: Date, end: Date) {
    let start = Int64(floor(start.timeIntervalSince1970 / 60) * 60_000)
    let end = Int64(floor(end.timeIntervalSince1970 / 60) * 60_000)
    if end <= start || end - start > 240 * 3_600_000 { show("結束須晚於開始，最長 240 小時"); return }
    customStart = start; customEnd = end; selectedTime = nil; playing = false
    cursorPoint = nil
    fitHistory = true; loadHistory()
  }

  var defaultCustomStart: Date { Date(timeIntervalSince1970: Double(customStart ?? now() - hours * 3_600_000) / 1000) }
  var defaultCustomEnd: Date { Date(timeIntervalSince1970: Double(customEnd ?? now()) / 1000) }

  func togglePlay() {
    guard let first = history.first, let last = history.last else { return }
    playing.toggle()
    if playing && (selectedTime == nil || selectedTime! >= last.time) { selectedTime = first.time }
    drawHistory()
  }

  func fullTrack() { playing = false; selectedTime = nil; drawHistory() }

  func sliderEditing(_ editing: Bool) { if editing { playing = false } }

  func setSlider(_ value: Double) {
    guard let first = history.first, let last = history.last else { return }
    let progress = Int64(value.rounded())
    selectedTime = first.time + (last.time - first.time) * progress / 1000
    drawHistory()
  }

  private func loadHistory() {
    if cursorDragging { return }
    queryVersion += 1
    let version = queryVersion
    lastQueryAt = now(); historyLoading = true
    let end = customEnd ?? lastQueryAt
    let start = customStart ?? end - hours * 3_600_000
    if fitHistory { history = []; map.clear(); detailText = "讀取歷史軌跡…" }
    worker.async { [weak self] in
      let result = Result { try LocationTrackerStore.shared().range(since: start, until: end) }
      Task { @MainActor in
        guard let self, version == self.queryVersion else { return }
        self.historyLoading = false
        switch result {
        case .success(let range):
          guard self.mode == .history else { return }
          self.history = range.points; self.historyTotal = range.total; self.historyTruncated = range.truncated
          self.drawHistory()
        case .failure:
          self.detailText = "歷史讀取失敗，請重新選擇時段重試"
        }
      }
    }
  }

  private func drawHistory() {
    if mode != .history || cursorDragging { return }
    let visible = selectedTime.map { selected in Array(history.prefix { $0.time <= selected }) } ?? history
    let end = customEnd ?? now()
    let start = customStart ?? end - hours * 3_600_000
    detailText = "\(date(start)) 至 \(date(end))\n共 \(historyTotal) 筆" +
      (historyTruncated ? " · 僅繪製最近 8,000 筆，資料庫記錄保留" : "") +
      (history.isEmpty ? " · 此時段沒有手機位置記錄" : "")
    playEnabled = history.count > 1
    if let first = history.first, let last = history.last {
      let span = last.time - first.time
      sliderProgress = span <= 0 ? 1000 : Double(((selectedTime ?? last.time) - first.time) * 1000 / span)
      playbackLabel = (selectedTime.map { "回放 \(date($0))" } ?? "完整軌跡") + " · \(date(first.time)) — \(date(last.time))"
    } else { playbackLabel = "尚無歷史資料" }
    map.clearOverlays()
    for segment in HistoryGeometry.segments(visible) {
      let coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
      if coordinates.count > 1 { map.addPolyline(coordinates) } else { map.addDot(coordinates[0]) }
    }
    map.setMarker(visible.last.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                  title: selectedTime == nil ? "最後手機位置" : "回放手機位置", snippet: visible.last.map { date($0.time) } ?? "")
    cursorPoints = HistoryGeometry.segments(visible, maxPoints: 8000).flatMap { $0 }
    let chosen = selectedTime != nil ? cursorPoints.last : (cursorPoints.first { $0.id == cursorPoint?.id } ?? cursorPoints.first)
    if let point = chosen {
      cursorPoint = point
      playbackLabel = "標定時間 \(cursorTime(point)) · 長按三角形可拖動"
    }
    map.setCursor(chosen.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }, title: chosen.map(cursorTime) ?? "")
    if fitHistory && !history.isEmpty {
      fitHistory = false
      let points = history
      DispatchQueue.main.async { [weak self] in
        guard let self, self.mode == .history else { return }
        if points.count == 1 {
          self.map.move(to: CLLocationCoordinate2D(latitude: points[0].latitude, longitude: points[0].longitude), zoom: 17, animated: false)
        } else {
          self.map.fit(points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }, padding: 45)
        }
      }
    }
  }

  private func snapHistoryCursor(_ coordinate: CLLocationCoordinate2D, finished: Bool) {
    let target = map.screenPoint(coordinate)
    let nearest = cursorPoints.min { a, b in
      let pa = map.screenPoint(CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude))
      let pb = map.screenPoint(CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude))
      return hypot(pa.x - target.x, pa.y - target.y) < hypot(pb.x - target.x, pb.y - target.y)
    }
    if let point = nearest {
      cursorPoint = point
      playbackLabel = "標定時間 \(cursorTime(point))"
      if finished {
        map.moveCursor(to: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), title: cursorTime(point))
      }
    }
    if finished { cursorDragging = false }
  }

  // MARK: Export

  /// The system share sheet (also offers "儲存影像" to Photos), presented from the top view controller.
  func shareExport() {
    guard let file = exportFile,
          let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController
    else { show("無法開啟匯出選單，請重試"); return }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    controller.popoverPresentationController?.sourceView = top.view
    top.present(controller, animated: true)
  }

  func exportMap() {
    if historyLoading || cursorDragging { show("請等待地圖載入完成後再匯出"); return }
    if exporting { return }
    playing = false
    let caption = ["PhoneTracker · \(mode == .history ? "歷史軌跡" : "即時位置")", detailText, mode == .history ? playbackLabel : ""]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    guard let snapshot = map.snapshot() else { show("地圖圖片尚未準備完成，請稍後重試"); return }
    exporting = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let file = try? MapExporter.compose(snapshot, caption: caption)
      Task { @MainActor in
        guard let self else { return }
        self.exporting = false
        if let file { self.exportFile = file; self.showExportOptions = true } else { self.show("無法匯出地圖，請重試") }
      }
    }
  }
}
