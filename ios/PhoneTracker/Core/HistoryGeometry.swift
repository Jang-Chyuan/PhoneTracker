import Foundation

enum HistoryGeometry {
  static func segments(_ points: [TrackPoint], maxPoints: Int = 4000, maxSegments: Int = 120) -> [[TrackPoint]] {
    var segments: [[TrackPoint]] = []
    var previous: TrackPoint?
    for point in points {
      if !point.latitude.isFinite || !point.longitude.isFinite || abs(point.latitude) > 90 || abs(point.longitude) > 180 {
        previous = nil
        continue
      }
      if let last = previous, point.session == last.session, point.time - last.time <= 120_000, point.time >= last.time,
         abs(point.longitude - last.longitude) <= 180 {
        segments[segments.count - 1].append(point)
      } else {
        segments.append([point])
      }
      previous = point
    }
    let visible = Array(segments.suffix(maxSegments))
    if visible.reduce(0, { $0 + $1.count }) <= maxPoints { return visible }
    let mandatory = visible.reduce(0) { $0 + min(2, $1.count) }
    var available = max(maxPoints - mandatory, 0)
    var interior = visible.reduce(0) { $0 + max($1.count - 2, 0) }
    return visible.map { segment in
      let inner = max(segment.count - 2, 0)
      let allocation = interior == 0 ? 0 : min(available, Int(ceil(Double(available) * Double(inner) / Double(interior))))
      available -= allocation; interior -= inner
      if segment.count <= allocation + 2 { return segment }
      return (0..<(allocation + 2)).map { segment[$0 * (segment.count - 1) / (allocation + 1)] }
    }
  }
}
