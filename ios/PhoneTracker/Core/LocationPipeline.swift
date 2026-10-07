import Foundation

struct LocationSample: Equatable {
  var latitude: Double
  var longitude: Double
  var accuracy: Float
  /// Monotonic receive clock in nanoseconds, comparable with `now` passed to the pipeline.
  var elapsedNanos: Int64
  /// Wall-clock fix time in milliseconds since 1970.
  var timestamp: Int64
  var speed: Float?
  var bearing: Float?
  var altitude: Double?
  var rawLatitude: Double
  var rawLongitude: Double
  var speedAccuracy: Float?
  var rawSpeed: Float?
  var motionState: String

  init(_ latitude: Double, _ longitude: Double, _ accuracy: Float, _ elapsedNanos: Int64, _ timestamp: Int64,
       _ speed: Float? = nil, bearing: Float? = nil, altitude: Double? = nil, rawLatitude: Double? = nil,
       rawLongitude: Double? = nil, speedAccuracy: Float? = nil, rawSpeed: Float?? = .none,
       motionState: String = "moving") {
    self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
    self.elapsedNanos = elapsedNanos; self.timestamp = timestamp; self.speed = speed
    self.bearing = bearing; self.altitude = altitude
    self.rawLatitude = rawLatitude ?? latitude; self.rawLongitude = rawLongitude ?? longitude
    self.speedAccuracy = speedAccuracy
    self.rawSpeed = rawSpeed ?? speed
    self.motionState = motionState
  }
}

/// Acquisition, display and persistence have separate clocks. Never replay old fixes.
final class LocationPipeline {
  private(set) var latest: LocationSample?
  private(set) var received = 0
  private(set) var accepted = 0
  private(set) var rejected = 0
  private(set) var reason = "等待新定位"
  private var lastSavedSample: Int64 = 0
  private var lastWrite: Int64 = 0
  private var newest: Int64 = 0
  private var window: [LocationSample] = []
  private let motion = MotionDetector()
  private var stationaryCoordinate: (Double, Double)?

  var intervalSeconds: Int {
    guard let speed = latest?.rawSpeed, speed.isFinite, speed >= 0 else { return 30 }
    if isFastLocation(speed) { return 1 }
    if speed > 10 / Float(3.6) { return 5 }
    return 30
  }

  @discardableResult
  func accept(_ input: LocationSample, now: Int64) -> Bool {
    received += 1
    func reject(_ message: String) -> Bool { rejected += 1; reason = message; return false }
    if input.elapsedNanos <= 0 || input.elapsedNanos > now || now - input.elapsedNanos > 3_000_000_000 {
      return reject("定位過期，等待新樣本")
    }
    if input.elapsedNanos <= newest { return reject("略過重複或倒序定位") }
    if !input.latitude.isFinite || !input.longitude.isFinite || abs(input.latitude) > 90 || abs(input.longitude) > 180 {
      return reject("定位座標無效")
    }
    if !acceptsLocationAccuracy(true, input.accuracy, input.rawSpeed) {
      return reject(isFastLocation(input.rawSpeed) ? "等待合格定位（需 < 50 公尺）" : "等待合格定位（需 ≤ 30 公尺）")
    }
    let previous = latest
    let dt = previous.map { Double(input.elapsedNanos - $0.elapsedNanos) / 1e9 } ?? 0
    let reset = previous == nil || dt > 30
    if !reset, let previous {
      let distance = distanceMeters(previous.rawLatitude, previous.rawLongitude, input.latitude, input.longitude)
      if distance > 70 * dt + Double(previous.accuracy) + Double(input.accuracy) {
        return reject("略過不合理位置跳動")
      }
    }
    // Three valid raw samples; a signal gap starts a new smoothing window.
    if reset || dt > 3 {
      window.removeAll()
      stationaryCoordinate = nil
    }
    window.append(input)
    while window.count > 3 { window.removeFirst() }
    let points = window
    let fast = input.speed.map { Double($0) * 3.6 > 10 } ?? false
    let weights: [Double] = fast && points.count > 1
      ? points.indices.map { $0 == points.count - 1 ? 0.9 : 0.1 / Double(points.count - 1) }
      : points.map { _ in 1.0 / Double(points.count) }
    let latitude = points.indices.reduce(0.0) { $0 + points[$1].latitude * weights[$1] }
    let offset = points.indices.reduce(0.0) {
      $0 + ((points[$1].longitude - input.longitude + 540).truncatingRemainder(dividingBy: 360) - 180) * weights[$1]
    }
    let state = motion.accept(input)
    let longitude = (input.longitude + offset + 540).truncatingRemainder(dividingBy: 360) - 180
    // Lock the smoothed position at confirmation, while continuing to judge raw fixes.
    if state == "stationary" {
      if stationaryCoordinate == nil { stationaryCoordinate = (latitude, longitude) }
    } else { stationaryCoordinate = nil }
    var value = input
    value.latitude = stationaryCoordinate?.0 ?? latitude
    value.longitude = stationaryCoordinate?.1 ?? longitude
    value.speed = state == "stationary" ? 0 : input.speed
    value.motionState = state
    latest = value
    newest = input.elapsedNanos
    accepted += 1; reason = "接收與平滑中"
    return true
  }

  func candidate(now: Int64) -> LocationSample? {
    guard let value = latest else { return nil }
    if now - value.elapsedNanos > 3_000_000_000 || value.elapsedNanos <= lastSavedSample { return nil }
    if lastWrite > 0 && now - lastWrite < Int64(intervalSeconds) * 1_000_000_000 { return nil }
    return value
  }

  func written(_ sample: LocationSample, now: Int64) { lastSavedSample = sample.elapsedNanos; lastWrite = now }
}
