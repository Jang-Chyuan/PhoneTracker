import Foundation

/// Map estimates never bypass the recording pipeline's accuracy checks.
final class LocationPreview {
  private(set) var latest: LocationSample?

  @discardableResult
  func accept(_ sample: LocationSample, now: Int64) -> Bool {
    if !sample.latitude.isFinite || !sample.longitude.isFinite ||
      !(-90.0...90.0).contains(sample.latitude) || !(-180.0...180.0).contains(sample.longitude) ||
      !sample.accuracy.isFinite || sample.accuracy < 0 || sample.elapsedNanos <= 0 ||
      sample.elapsedNanos > now || now - sample.elapsedNanos > 30_000_000_000 ||
      sample.elapsedNanos <= (latest?.elapsedNanos ?? 0) { return false }
    latest = sample
    return true
  }
}
