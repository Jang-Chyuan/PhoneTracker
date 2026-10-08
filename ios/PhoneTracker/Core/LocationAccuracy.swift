import Foundation

func isFastLocation(_ speed: Float?) -> Bool {
  guard let speed else { return false }
  return speed.isFinite && speed > 20 / Float(3.6)
}

func acceptsLocationAccuracy(_ hasAccuracy: Bool, _ meters: Float, _ speed: Float? = nil) -> Bool {
  hasAccuracy && meters.isFinite && meters >= 0 &&
    (isFastLocation(speed) ? meters < 50 : meters <= 30)
}

/// Great-circle distance on the 6,371 km sphere used by the Android pipeline.
func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
  let radians = Double.pi / 180
  let dlat = (lat2 - lat1) * radians, dlon = (lon2 - lon1) * radians
  let a = pow(sin(dlat / 2), 2) + cos(lat1 * radians) * cos(lat2 * radians) * pow(sin(dlon / 2), 2)
  return 12_742_000 * asin(sqrt(min(max(a, 0), 1)))
}
