import Foundation

/// The map marker's animated coordinate, saved instead of the pipeline coordinate when it is current.
struct DisplayLocation: Equatable {
  var session: String
  var fixTime: Int64
  var latitude: Double
  var longitude: Double
  var receivedNanos: Int64

  func usable(_ sessionId: String, _ sample: LocationSample, now: Int64) -> Bool {
    session == sessionId && sample.timestamp >= fixTime && sample.timestamp - fixTime <= 3000 &&
      now >= receivedNanos && now - receivedNanos <= 1_500_000_000 &&
      latitude.isFinite && longitude.isFinite &&
      distanceMeters(latitude, longitude, sample.latitude, sample.longitude) <= 300 + Double(sample.accuracy)
  }
}
