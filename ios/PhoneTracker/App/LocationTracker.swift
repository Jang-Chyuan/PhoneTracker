import ActivityKit
import CoreLocation
import Foundation

/// Monotonic clock that keeps counting while the phone sleeps, like Android's elapsedRealtimeNanos().
func monotonicNanos() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC)) }

struct LivePosition: Equatable {
  var latitude: Double, longitude: Double, timestamp: Int64, accuracy: Float
  var speedKmh: Double?, rawSpeedKmh: Double?, speedAccuracyMps: Float?, motionState: String, bearing: Float?
}

struct LiveStatus: Equatable {
  var running = false
  var status = "尚未開始記錄"
  var received = 0, accepted = 0, rejected = 0, saved = 0, writeErrors = 0
  var ageSeconds: Double?
  var intervalSeconds = 30
  var sessionId = ""
  var position: LivePosition?
}

/// Equivalent of the Android LocationTrackerService: acquisition and storage continue without the screen.
/// iOS keeps the app running in the background through the location background mode and a
/// CLBackgroundActivitySession (blue status-bar indicator) instead of a foreground-service notification.
final class LocationTracker: NSObject, CLLocationManagerDelegate {
  static let shared = LocationTracker()

  let manager = CLLocationManager()
  private let worker = DispatchQueue(label: "PhoneLocationWriter")
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var store: LocationTrackerStore?
  private var pipeline = LocationPipeline()
  private var sessionId = UUID().uuidString
  private var saved = 0
  private var writeErrors = 0
  private var stopped = true
  private var backgroundSession: CLBackgroundActivitySession?
  private var activity: Activity<RecordingActivityAttributes>?
  private var _live = LiveStatus()
  private var _display: DisplayLocation?
  /// CLLocationManager reports .notDetermined until its first authorization callback; decide only after it.
  private(set) var authorizationResolved = false
  /// Called on the main queue when the authorization prompt resolves.
  var onAuthorizationChange: (() -> Void)?

  let preferences = UserDefaults.standard
  var enabled: Bool {
    get { preferences.object(forKey: "enabled") as? Bool ?? true }
    set { preferences.set(newValue, forKey: "enabled") }
  }

  var live: LiveStatus { lock.lock(); defer { lock.unlock() }; return _live }
  var running: Bool { live.running }
  /// The screen's animated marker coordinate; saved instead of the pipeline coordinate while current.
  var displayLocation: DisplayLocation? {
    get { lock.lock(); defer { lock.unlock() }; return _display }
    set { lock.lock(); _display = newValue; lock.unlock() }
  }

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .other
    manager.pausesLocationUpdatesAutomatically = false
  }

  /// Start recording. Returns an error message when it cannot start (permission, precision, GPS off).
  @discardableResult
  func start(fromBackground: Bool = false) -> String? {
    // A queued automatic start must not undo a later explicit stop.
    if !enabled { return nil }
    if running { return nil }
    let status = manager.authorizationStatus
    guard status == .authorizedAlways || (status == .authorizedWhenInUse && !fromBackground) else {
      setStatus("無法開始記錄，請允許精確位置並開啟 GPS"); return "請允許位置權限"
    }
    guard manager.accuracyAuthorization == .fullAccuracy else {
      setStatus("無法開始記錄，請允許精確位置並開啟 GPS"); return "請允許精確位置，僅概略位置無法記錄"
    }
    guard CLLocationManager.locationServicesEnabled() else {
      setStatus("無法開始記錄，請允許精確位置並開啟 GPS"); return "請開啟手機定位服務"
    }
    worker.sync {
      pipeline = LocationPipeline()
      sessionId = UUID().uuidString
      saved = 0; writeErrors = 0; stopped = false
    }
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
    manager.startUpdatingLocation()
    // Lets the system relaunch the app after it was terminated, then recording resumes in resumeAfterLaunch().
    if status == .authorizedAlways { manager.startMonitoringSignificantLocationChanges() }
    if !fromBackground { backgroundSession = CLBackgroundActivitySession() }
    startActivity()
    lock.lock()
    _live = LiveStatus(running: true, status: "等待合格定位：≤ 30 m；> 20 km/h 時 < 50 m", sessionId: sessionId)
    lock.unlock()
    let timer = DispatchSource.makeTimerSource(queue: worker)
    timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
    return nil
  }

  /// Explicit stop from the screen or the Live Activity; recording stays off until started again.
  func stop() {
    enabled = false
    timer?.cancel(); timer = nil
    worker.sync { stopped = true }
    manager.stopUpdatingLocation()
    manager.stopMonitoringSignificantLocationChanges()
    manager.allowsBackgroundLocationUpdates = false
    backgroundSession?.invalidate(); backgroundSession = nil
    endActivity()
    lock.lock()
    let wasRunning = _live.running
    _live = LiveStatus(running: false, status: wasRunning ? "已停止記錄" : _live.status)
    _display = nil
    lock.unlock()
  }

  /// Relaunch after the system ended the app: resume like Android's START_STICKY when recording is still enabled.
  func resumeAfterLaunch(inBackground: Bool) {
    guard enabled, !running else { return }
    let status = manager.authorizationStatus
    if status == .authorizedAlways || (status == .authorizedWhenInUse && !inBackground) { start(fromBackground: inBackground) }
  }

  private func setStatus(_ message: String) { lock.lock(); _live.status = message; lock.unlock() }

  private func tick() {
    if stopped { return }
    let now = monotonicNanos()
    var writeFailed = false
    var status: String
    if let sample = pipeline.candidate(now: now) {
      do {
        let database = try store ?? LocationTrackerStore.shared()
        store = database
        let display = displayLocation.flatMap { $0.usable(sessionId, sample, now: now) ? $0 : nil }
        try database.save(sample, session: sessionId, display: display)
        pipeline.written(sample, now: now); saved += 1
      } catch { writeErrors += 1; writeFailed = true }
    }
    let latest = pipeline.latest
    let age = latest.map { Double(now - $0.elapsedNanos) / 1e9 }
    if writeFailed { status = "Timeline 寫入失敗，下一秒重試" }
    else { status = (age ?? 0) > 3 ? "等待合格新定位；最後位置已過期" : pipeline.reason }
    var value = LiveStatus(running: true, status: status, received: pipeline.received, accepted: pipeline.accepted,
                           rejected: pipeline.rejected, saved: saved, writeErrors: writeErrors, ageSeconds: age,
                           intervalSeconds: pipeline.intervalSeconds, sessionId: sessionId)
    if let latest {
      value.position = LivePosition(latitude: latest.latitude, longitude: latest.longitude, timestamp: latest.timestamp,
        accuracy: latest.accuracy, speedKmh: latest.speed.map { Double($0) * 3.6 }, rawSpeedKmh: latest.rawSpeed.map { Double($0) * 3.6 },
        speedAccuracyMps: latest.speedAccuracy, motionState: (age ?? 0) > 3 ? "unknown" : latest.motionState, bearing: latest.bearing)
    }
    lock.lock(); if _live.running { _live = value }; lock.unlock()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let receivedAt = monotonicNanos()
    let wallNow = Date()
    let samples = locations.map { location -> LocationSample in
      // CLLocation carries wall-clock time only; place the fix on the monotonic clock by its age.
      let ageNanos = Int64(max(0, wallNow.timeIntervalSince(location.timestamp)) * 1e9)
      let speed: Float? = location.speed >= 0 && location.speed.isFinite ? Float(location.speed) : nil
      let speedAccuracy: Float? = location.speedAccuracy >= 0 && location.speedAccuracy.isFinite ? Float(location.speedAccuracy) : nil
      return LocationSample(location.coordinate.latitude, location.coordinate.longitude,
        location.horizontalAccuracy >= 0 ? Float(location.horizontalAccuracy) : .nan,
        receivedAt - ageNanos, Int64(location.timestamp.timeIntervalSince1970 * 1000), speed,
        bearing: location.course >= 0 && location.course.isFinite ? Float(location.course) : nil,
        altitude: location.verticalAccuracy > 0 && location.altitude.isFinite ? location.altitude : nil,
        speedAccuracy: speedAccuracy)
    }
    worker.async { [self] in
      if stopped { return }
      for sample in samples { pipeline.accept(sample, now: monotonicNanos()) }
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if (error as? CLError)?.code == .denied { setStatus("定位來源已關閉，等待恢復") }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationResolved = true
    if running && (manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted) {
      setStatus("定位來源已關閉，等待恢復")
    }
    DispatchQueue.main.async { self.onAuthorizationChange?() }
  }

  // MARK: Live Activity: the lock-screen counterpart of the Android notification with "停止記錄".

  private func startActivity() {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    for existing in Activity<RecordingActivityAttributes>.activities {
      Task { await existing.end(nil, dismissalPolicy: .immediate) }
    }
    activity = try? Activity.request(attributes: RecordingActivityAttributes(),
                                     content: .init(state: .init(startedAt: Date()), staleDate: nil))
  }

  private func endActivity() {
    let activities = Activity<RecordingActivityAttributes>.activities
    activity = nil
    for item in activities { Task { await item.end(nil, dismissalPolicy: .immediate) } }
  }
}
