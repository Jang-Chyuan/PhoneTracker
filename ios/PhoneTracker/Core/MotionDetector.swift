import Foundation

/// Judges raw samples; LocationPipeline applies the stationary speed and position lock.
final class MotionDetector {
  private var history: [LocationSample] = []
  private var state = "moving"
  private var anchor: LocationSample?
  private var resumeSince: Int64?
  private var lastTime: Int64 = 0

  func accept(_ point: LocationSample) -> String {
    if lastTime > 0 && point.elapsedNanos - lastTime > 3_000_000_000 { reset() }
    lastTime = point.elapsedNanos
    let uncertainty = point.speedAccuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    guard let speed = point.rawSpeed, speed.isFinite, speed >= 0, !(point.accuracy > 10) else {
      reset(); return "unknown"
    }
    let credibleMovement = uncertainty.map { speed - $0 > 0.5 } ?? (speed > 1)
    let low = speed <= 1 && !credibleMovement && (uncertainty.map { $0 <= 1 } ?? (speed <= 0.3))
    if state == "stationary", let anchor {
      let departing = distance(anchor, point) > max(5.0, Double(point.accuracy))
      if credibleMovement || departing {
        let start = resumeSince ?? point.elapsedNanos
        resumeSince = start
        if point.elapsedNanos - start >= 3_000_000_000 {
          reset(); return "moving"
        }
      } else {
        resumeSince = nil
        if !low { reset(); return "unknown" }
      }
      return state
    }
    if !low { reset(); return credibleMovement ? "moving" : "unknown" }
    history.append(point)
    while history.count > 1 && point.elapsedNanos - history[1].elapsedNanos >= 20_000_000_000 { history.removeFirst() }
    let first = history[0]
    let net = distance(first, point)
    let path = zip(history, history.dropFirst()).reduce(0.0) { $0 + distance($1.0, $1.1) }
    let directional = net > 3.0 && path > 0 && net / path > 0.75
    let clustered = history.allSatisfy { distance(first, $0) <= 5.0 }
    if !clustered || directional { reset(); return "moving" }
    let seconds = Double(point.elapsedNanos - first.elapsedNanos) / 1e9
    state = seconds >= 20 ? "stationary" : seconds >= 15 ? "suspected_stationary" : "moving"
    if state == "stationary" { anchor = first }
    return state
  }

  private func reset() { history.removeAll(); state = "moving"; anchor = nil; resumeSince = nil }

  private func distance(_ a: LocationSample, _ b: LocationSample) -> Double {
    distanceMeters(a.rawLatitude, a.rawLongitude, b.rawLatitude, b.rawLongitude)
  }
}
