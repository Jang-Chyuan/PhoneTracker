import XCTest
@testable import PhoneTracker

final class HistoryGeometryTests: XCTestCase {
  private func point(_ id: Int64, time: Int64? = nil, session: String = "a", lon: Double = 121.0) -> TrackPoint {
    TrackPoint(id: id, time: time ?? id * 1000, latitude: 25.0, longitude: lon, accuracy: 10, speed: 0, session: session, motion: "moving")
  }
  func testGapsAndSessionsNeverConnect() {
    let segments = HistoryGeometry.segments([point(1), point(2), point(3, time: 200_000), point(4, time: 201_000, session: "b")])
    XCTAssertEqual(segments.map(\.count), [2, 1, 1])
  }
  func testDatelineAndInvalidLocationsBreakSegments() {
    let segments = HistoryGeometry.segments([point(1, lon: 179.9), point(2, lon: -179.9), point(3, lon: .nan), point(4)])
    XCTAssertEqual(segments.map(\.count), [1, 1, 1])
  }
  func testDrawingBudgetRetainsEndpointsWithoutChangingStoredPoints() {
    let points = (Int64(1)...8000).map { point($0) }
    let output = HistoryGeometry.segments(points)
    XCTAssertEqual(output.reduce(0) { $0 + $1.count }, 4000)
    XCTAssertEqual(output.first!.first!.id, 1)
    XCTAssertEqual(output.last!.last!.id, 8000)
    XCTAssertEqual(points.count, 8000)
  }
  static let allTests = [
    ("testGapsAndSessionsNeverConnect", testGapsAndSessionsNeverConnect),
    ("testDatelineAndInvalidLocationsBreakSegments", testDatelineAndInvalidLocationsBreakSegments),
    ("testDrawingBudgetRetainsEndpointsWithoutChangingStoredPoints", testDrawingBudgetRetainsEndpointsWithoutChangingStoredPoints),
  ]
}

/// The Android store has no unit test; these pin the same SQL behavior (display coordinates, retention, paging).
final class LocationTrackerStoreTests: XCTestCase {
  private func makeStore() throws -> (LocationTrackerStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("phonetracker-test-\(UUID().uuidString).sqlite")
    return (try LocationTrackerStore(path: url.path), url)
  }
  private func sample(_ i: Int64) -> LocationSample {
    LocationSample(25 + Double(i) * 0.0001, 121.0, 5, i * 1_000_000_000, 1_000_000 + i * 1000, 2, bearing: 90, speedAccuracy: 0.3)
  }
  func testSavesDisplayCoordinateAndQueriesRangeOldestFirst() throws {
    let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
    var now: Int64 = 5_000
    store.clock = { now }
    try store.save(sample(1), session: "s")
    now = 6_000
    try store.save(sample(2), session: "s", display: DisplayLocation(session: "s", fixTime: 1_002_000, latitude: 25.5, longitude: 121.5, receivedNanos: 0))
    now = 7_000
    try store.save(sample(3), session: "t")
    let range = try store.range(since: 5_000, until: 7_000)
    XCTAssertEqual(range.points.map(\.time), [5_000, 6_000])
    XCTAssertEqual(range.total, 2)
    XCTAssertFalse(range.truncated)
    XCTAssertEqual(range.points[0].latitude, sample(1).latitude, accuracy: 0)
    XCTAssertEqual(range.points[1].latitude, 25.5, accuracy: 0)
    XCTAssertEqual(range.points[1].longitude, 121.5, accuracy: 0)
    XCTAssertEqual(range.points[0].speed!, 7.2, accuracy: 1e-5)
    XCTAssertEqual(range.points[0].session, "s")
    XCTAssertEqual(try store.count(), 3)
  }
  func testRetentionKeepsNewestEightyThousandAndRangeIsBounded() throws {
    let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
    var now: Int64 = 0
    store.clock = { now }
    for i in Int64(1)...Int64(LocationTrackerStore.maxRecords + 5) { now = i; try store.save(sample(i), session: "s") }
    XCTAssertEqual(try store.count(), Int64(LocationTrackerStore.maxRecords))
    XCTAssertEqual(try store.count(since: 0, until: 6), 0)
    let range = try store.range(since: 0, until: .max)
    XCTAssertEqual(range.points.count, 8000)
    XCTAssertTrue(range.truncated)
    XCTAssertEqual(range.points.last!.time, Int64(LocationTrackerStore.maxRecords + 5))
    let page = try store.page()
    XCTAssertEqual(page.points.count, 50)
    XCTAssertTrue(page.hasMore)
    let next = try store.page(before: page.points.last!.id)
    XCTAssertEqual(next.points.first!.id, page.points.last!.id - 1)
  }
  static let allTests = [
    ("testSavesDisplayCoordinateAndQueriesRangeOldestFirst", testSavesDisplayCoordinateAndQueriesRangeOldestFirst),
    ("testRetentionKeepsNewestEightyThousandAndRangeIsBounded", testRetentionKeepsNewestEightyThousandAndRangeIsBounded),
  ]
}
