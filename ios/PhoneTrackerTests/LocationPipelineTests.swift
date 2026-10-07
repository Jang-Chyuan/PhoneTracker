import XCTest
@testable import PhoneTracker

/// Ported one-for-one from app/src/test (Android) so both apps judge fixes identically.
final class LocationAccuracyTests: XCTestCase {
  func testFastSpeedAllowsOnlyAccuracyStrictlyBelowFifty() {
    XCTAssertFalse(acceptsLocationAccuracy(true, 40, 20 / Float(3.6)))
    XCTAssertTrue(acceptsLocationAccuracy(true, 49.99, 20.1 / Float(3.6)))
    XCTAssertFalse(acceptsLocationAccuracy(true, 50, 30))
    for speed: Float? in [nil, -1, .nan, .infinity] { XCTAssertFalse(acceptsLocationAccuracy(true, 40, speed)) }
  }
  func testAcceptsBoundaryAndBetterFixes() {
    XCTAssertTrue(acceptsLocationAccuracy(true, 5))
    XCTAssertTrue(acceptsLocationAccuracy(true, 30))
    XCTAssertTrue(acceptsLocationAccuracy(true, 2.5))
  }
  func testRejectsPoorMissingAndInvalidAccuracy() {
    for meters: Float in [30.001, 100, -1, .nan, .infinity] { XCTAssertFalse(acceptsLocationAccuracy(true, meters)) }
    XCTAssertFalse(acceptsLocationAccuracy(false, 0))
  }
  static let allTests = [
    ("testFastSpeedAllowsOnlyAccuracyStrictlyBelowFifty", testFastSpeedAllowsOnlyAccuracyStrictlyBelowFifty),
    ("testAcceptsBoundaryAndBetterFixes", testAcceptsBoundaryAndBetterFixes),
    ("testRejectsPoorMissingAndInvalidAccuracy", testRejectsPoorMissingAndInvalidAccuracy),
  ]
}

final class LocationPipelineTests: XCTestCase {
  private func sample(_ second: Int64, lat: Double = 25.0, speed: Float? = 0, accuracy: Float = 10) -> LocationSample {
    LocationSample(lat, 121.0, accuracy, second * 1_000_000_000, second * 1000, speed)
  }
  func testThreePointsAndHighSpeedWeight() {
    let slow = LocationPipeline(), fast = LocationPipeline()
    for i: Int64 in 1...3 {
      slow.accept(sample(i, lat: 25 + Double(i) * 0.00001), now: i * 1_000_000_000)
      fast.accept(sample(i, lat: 25 + Double(i) * 0.00001, speed: 5), now: i * 1_000_000_000)
    }
    XCTAssertEqual(slow.latest!.latitude, 25.00002, accuracy: 1e-8)
    XCTAssertTrue(fast.latest!.latitude > slow.latest!.latitude)
    XCTAssertEqual(slow.latest!.rawLatitude, 25.00003, accuracy: 1e-8)
    XCTAssertEqual(slow.latest!.accuracy, 10)
  }
  func testWritesEveryThirtySecondsAndNeverReplaysAnOldFix() {
    let pipe = LocationPipeline()
    for i: Int64 in 1...61 {
      let now = i * 1_000_000_000
      pipe.accept(sample(i), now: now)
      let candidate = pipe.candidate(now: now)
      if [1, 31, 61].contains(i) { XCTAssertNotNil(candidate); pipe.written(candidate!, now: now) }
      else { XCTAssertNil(candidate) }
    }
    XCTAssertNil(pipe.candidate(now: 100_000_000_000))
  }
  func testAdaptiveBoundariesAccelerationAndDeceleration() {
    for (kmh, interval) in [(Float(0), 30), (10, 30), (10.1, 5), (20, 5), (20.1, 1), (60, 1)] {
      let pipe = LocationPipeline()
      pipe.accept(sample(1, speed: kmh / Float(3.6)), now: 1_000_000_000)
      XCTAssertEqual(pipe.intervalSeconds, interval, "\(kmh) km/h")
    }
    let pipe = LocationPipeline()
    for i: Int64 in 1...21 { pipe.accept(sample(i, speed: 0), now: i * 1_000_000_000) }
    pipe.written(pipe.candidate(now: 21_000_000_000)!, now: 21_000_000_000)
    pipe.accept(sample(22, speed: 30), now: 22_000_000_000)
    // Departure is still in the stationary grace period, but raw speed controls writes.
    XCTAssertEqual(pipe.latest!.speed, 0)
    XCTAssertEqual(pipe.intervalSeconds, 1)
    let fast = pipe.candidate(now: 22_000_000_000)!
    pipe.written(fast, now: 22_000_000_000)
    XCTAssertNil(pipe.candidate(now: 23_000_000_000)) // Never duplicate the saved sample.
    pipe.accept(sample(23, speed: 0), now: 23_000_000_000)
    XCTAssertEqual(pipe.intervalSeconds, 30)
    XCTAssertNil(pipe.candidate(now: 23_000_000_000))
    pipe.accept(sample(27, speed: nil), now: 27_000_000_000)
    XCTAssertEqual(pipe.intervalSeconds, 30)
    XCTAssertNil(pipe.candidate(now: 27_000_000_000))
    pipe.accept(sample(52, speed: nil), now: 52_000_000_000)
    XCTAssertNotNil(pipe.candidate(now: 52_000_000_000))
  }
  func testRejectsBadAccuracyStaleAndJumpingFixesWithoutConsumingWriteSlot() {
    let pipe = LocationPipeline()
    XCTAssertFalse(pipe.accept(sample(1, accuracy: 31), now: 1_000_000_000))
    XCTAssertFalse(pipe.accept(sample(1), now: 5_000_000_000))
    XCTAssertTrue(pipe.accept(sample(6, accuracy: 30), now: 6_000_000_000))
    XCTAssertFalse(pipe.accept(sample(7, lat: 26.0), now: 7_000_000_000))
    XCTAssertNotNil(pipe.candidate(now: 7_000_000_000))
    XCTAssertEqual(pipe.rejected, 3)
    // Long outages reset rather than dragging the old location forward.
    XCTAssertTrue(pipe.accept(sample(50, lat: 26.0), now: 50_000_000_000))
    XCTAssertEqual(pipe.latest!.latitude, 26.0, accuracy: 0)
  }
  static let allTests = [
    ("testThreePointsAndHighSpeedWeight", testThreePointsAndHighSpeedWeight),
    ("testWritesEveryThirtySecondsAndNeverReplaysAnOldFix", testWritesEveryThirtySecondsAndNeverReplaysAnOldFix),
    ("testAdaptiveBoundariesAccelerationAndDeceleration", testAdaptiveBoundariesAccelerationAndDeceleration),
    ("testRejectsBadAccuracyStaleAndJumpingFixesWithoutConsumingWriteSlot", testRejectsBadAccuracyStaleAndJumpingFixesWithoutConsumingWriteSlot),
  ]
}

final class DrivingPipelineTests: XCTestCase {
  private func point(_ t: Int64, _ meters: Double, _ kmh: Double, _ accuracy: Float = 3) -> LocationSample {
    LocationSample(25 + meters / 111195, 121.0, accuracy, t * 1_000_000_000, t * 1000, Float(kmh / 3.6), speedAccuracy: 0.2)
  }
  func testFastLowerPrecisionFixesProduceFreshPointsEverySecond() {
    let pipeline = LocationPipeline()
    for t: Int64 in 1...10 {
      let sample = point(t, Double(t) * 10.0, 36.0, 49)
      XCTAssertTrue(pipeline.accept(sample, now: sample.elapsedNanos))
      let saved = pipeline.candidate(now: sample.elapsedNanos)!
      XCTAssertEqual(saved.timestamp, sample.timestamp)
      XCTAssertEqual(saved.speed, sample.speed)
      pipeline.written(saved, now: sample.elapsedNanos)
      XCTAssertNil(pipeline.candidate(now: sample.elapsedNanos))
    }
  }
  func testCityAndHighwayDrivingProduceAdaptiveWritesWithoutZeroing() {
    for kmh in [15.0, 20.0, 30.0, 60.0, 120.0] {
      let pipeline = LocationPipeline()
      var saved: [LocationSample] = []
      for t: Int64 in 1...61 {
        let sample = point(t, Double(t) * kmh / 3.6, kmh)
        XCTAssertTrue(pipeline.accept(sample, now: sample.elapsedNanos))
        XCTAssertEqual(pipeline.latest!.motionState, "moving")
        XCTAssertEqual(pipeline.latest!.speed, sample.speed)
        // High-speed smoothing trails by less than 0.2 seconds of travel.
        XCTAssertTrue((sample.latitude - pipeline.latest!.latitude) * 111195 < kmh / 3.6 * 0.2)
        if let candidate = pipeline.candidate(now: sample.elapsedNanos) {
          saved.append(candidate); pipeline.written(candidate, now: sample.elapsedNanos)
        }
      }
      let interval: Int64 = kmh > 20 ? 1 : 5
      XCTAssertEqual(saved.count, Int(60 / interval + 1), "\(kmh) km/h")
      XCTAssertTrue(zip(saved, saved.dropFirst()).allSatisfy { $1.timestamp - $0.timestamp == interval * 1000 })
      XCTAssertEqual(pipeline.rejected, 0)
    }
  }
  func testTrafficLightDepartureUnlocksCoordinatesAndSpeedAfterThreeSeconds() {
    let pipeline = LocationPipeline()
    for t: Int64 in 1...21 {
      let sample = point(t, 0, 0)
      pipeline.accept(sample, now: sample.elapsedNanos)
    }
    XCTAssertEqual(pipeline.latest!.motionState, "stationary")
    let locked = pipeline.latest!.latitude
    for t: Int64 in 22...25 {
      let sample = point(t, Double(t - 21) * 10.0, 36.0)
      XCTAssertTrue(pipeline.accept(sample, now: sample.elapsedNanos))
      if t < 25 { XCTAssertEqual(pipeline.latest!.latitude, locked, accuracy: 0) }
      else { XCTAssertTrue(pipeline.latest!.latitude > locked) }
      XCTAssertEqual(pipeline.latest!.rawLatitude, sample.rawLatitude, accuracy: 0)
      XCTAssertEqual(pipeline.latest!.rawSpeed, sample.rawSpeed)
      XCTAssertEqual(pipeline.latest!.speed, t < 25 ? 0 : 10)
    }
    XCTAssertEqual(pipeline.latest!.motionState, "moving")
  }
  func testReducedAccuracyStillRecordsAndOutageDoesNotReplayOldPositions() {
    let pipeline = LocationPipeline()
    let first = point(1, 0, 60, 20)
    XCTAssertTrue(pipeline.accept(first, now: first.elapsedNanos))
    XCTAssertEqual(pipeline.latest!.motionState, "unknown")
    XCTAssertEqual(pipeline.latest!.speed, first.speed)
    pipeline.written(pipeline.candidate(now: first.elapsedNanos)!, now: first.elapsedNanos)
    let poor = point(6, 83.3, 60, 50)
    XCTAssertFalse(pipeline.accept(poor, now: poor.elapsedNanos))
    XCTAssertNil(pipeline.candidate(now: poor.elapsedNanos))
    let recovered = point(40, 650, 60)
    XCTAssertTrue(pipeline.accept(recovered, now: recovered.elapsedNanos))
    XCTAssertNotNil(pipeline.candidate(now: recovered.elapsedNanos))
    XCTAssertEqual(pipeline.latest!.motionState, "moving")
  }
  static let allTests = [
    ("testFastLowerPrecisionFixesProduceFreshPointsEverySecond", testFastLowerPrecisionFixesProduceFreshPointsEverySecond),
    ("testCityAndHighwayDrivingProduceAdaptiveWritesWithoutZeroing", testCityAndHighwayDrivingProduceAdaptiveWritesWithoutZeroing),
    ("testTrafficLightDepartureUnlocksCoordinatesAndSpeedAfterThreeSeconds", testTrafficLightDepartureUnlocksCoordinatesAndSpeedAfterThreeSeconds),
    ("testReducedAccuracyStillRecordsAndOutageDoesNotReplayOldPositions", testReducedAccuracyStillRecordsAndOutageDoesNotReplayOldPositions),
  ]
}

final class MotionDetectorTests: XCTestCase {
  private func point(_ t: Int64, _ meters: Double = 0, speed: Float? = 0.6, uncertainty: Float? = 0.4) -> LocationSample {
    LocationSample(25 + meters / 111195, 121.0, 3, t * 1_000_000_000, t * 1000, speed, speedAccuracy: uncertainty)
  }
  func testStationaryLocksCoordinatesAfterTwentySecondsAndPreservesRawSamples() {
    let pipe = LocationPipeline()
    for t: Int64 in 1...21 {
      let p = point(t, t % 2 == 0 ? 0.5 : 0)
      pipe.accept(p, now: p.elapsedNanos)
      let value = pipe.latest!
      XCTAssertEqual(value.motionState, t >= 21 ? "stationary" : t >= 16 ? "suspected_stationary" : "moving", "t=\(t)")
      XCTAssertEqual(value.rawSpeed, 0.6)
      XCTAssertEqual(value.speed, t >= 21 ? 0 : 0.6)
    }
    let before = pipe.latest!.latitude
    let next = point(22, 1.0)
    pipe.accept(next, now: next.elapsedNanos)
    XCTAssertEqual(pipe.latest!.latitude, before, accuracy: 0)
    XCTAssertEqual(pipe.latest!.rawLatitude, next.rawLatitude, accuracy: 0)
    XCTAssertEqual(pipe.latest!.timestamp, next.timestamp)
    let later = point(26, 2.0)
    XCTAssertNil(pipe.candidate(now: later.elapsedNanos))
    pipe.accept(later, now: later.elapsedNanos)
    XCTAssertEqual(pipe.latest!.motionState, "moving")
    XCTAssertEqual(pipe.latest!.latitude, later.latitude, accuracy: 0)
    XCTAssertEqual(pipe.latest!.speed, later.speed)
    for t: Int64 in 27...45 { pipe.accept(point(t, 2.0), now: t * 1_000_000_000) }
    XCTAssertEqual(pipe.latest!.motionState, "suspected_stationary")
    pipe.accept(point(46, 2.0), now: 46_000_000_000)
    XCTAssertEqual(pipe.latest!.motionState, "stationary")
  }
  func testSlowDirectionalWalkIsNotStationary() {
    let detector = MotionDetector()
    for t: Int64 in 1...60 { XCTAssertNotEqual(detector.accept(point(t, Double(t) * 0.4)), "stationary") }
  }
  func testReliableMovementNeedsThreeSecondsAndGapsReset() {
    let detector = MotionDetector()
    for t: Int64 in 1...21 { _ = detector.accept(point(t)) }
    for t: Int64 in 22...24 { XCTAssertEqual(detector.accept(point(t, speed: 2, uncertainty: 0.1)), "stationary") }
    XCTAssertEqual(detector.accept(point(25, speed: 2, uncertainty: 0.1)), "moving")
    for t: Int64 in 26...46 { _ = detector.accept(point(t)) }
    XCTAssertEqual(detector.accept(point(50)), "moving")
    XCTAssertEqual(detector.accept(point(51, speed: nil)), "unknown")
    XCTAssertEqual(detector.accept(point(52, uncertainty: nil)), "unknown")
    var poor = point(53); poor.accuracy = 30
    XCTAssertEqual(detector.accept(poor), "unknown")
  }
  func testLeavingStationaryCenterRestoresSpeedWithoutReliableSpeedAccuracy() {
    let detector = MotionDetector()
    for t: Int64 in 1...21 { _ = detector.accept(point(t)) }
    for t: Int64 in 22...24 { XCTAssertEqual(detector.accept(point(t, 8.0, speed: 0.2, uncertainty: nil)), "stationary") }
    XCTAssertEqual(detector.accept(point(25, 9.0, speed: 0.2, uncertainty: nil)), "moving")
  }
  static let allTests = [
    ("testStationaryLocksCoordinatesAfterTwentySecondsAndPreservesRawSamples", testStationaryLocksCoordinatesAfterTwentySecondsAndPreservesRawSamples),
    ("testSlowDirectionalWalkIsNotStationary", testSlowDirectionalWalkIsNotStationary),
    ("testReliableMovementNeedsThreeSecondsAndGapsReset", testReliableMovementNeedsThreeSecondsAndGapsReset),
    ("testLeavingStationaryCenterRestoresSpeedWithoutReliableSpeedAccuracy", testLeavingStationaryCenterRestoresSpeedWithoutReliableSpeedAccuracy),
  ]
}

final class DisplayLocationTests: XCTestCase {
  func testRejectsStaleFutureAndPreviousSessionDisplayCoordinates() {
    let sample = LocationSample(25.0, 121.0, 3, 10_000_000_000, 10000)
    let display = DisplayLocation(session: "a", fixTime: 9000, latitude: 25.00001, longitude: 121.00001, receivedNanos: 9_000_000_000)
    XCTAssertTrue(display.usable("a", sample, now: 10_000_000_000))
    var far = display; far.latitude = 24.98
    XCTAssertFalse(far.usable("a", sample, now: 10_000_000_000))
    XCTAssertFalse(display.usable("b", sample, now: 10_000_000_000))
    XCTAssertFalse(display.usable("a", sample, now: 11_000_000_000))
    var future = display; future.fixTime = 11000
    XCTAssertFalse(future.usable("a", sample, now: 10_000_000_000))
    var old = display; old.fixTime = 6000
    XCTAssertFalse(old.usable("a", sample, now: 10_000_000_000))
  }
  static let allTests = [
    ("testRejectsStaleFutureAndPreviousSessionDisplayCoordinates", testRejectsStaleFutureAndPreviousSessionDisplayCoordinates),
  ]
}
