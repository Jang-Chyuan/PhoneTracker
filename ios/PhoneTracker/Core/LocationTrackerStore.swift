import Foundation
import SQLite3

struct TrackPoint: Equatable, Identifiable {
  var id: Int64
  var time: Int64
  var latitude: Double
  var longitude: Double
  var accuracy: Double
  var speed: Double?
  var session: String
  var motion: String
}
struct TrackPage { var points: [TrackPoint]; var total: Int64; var hasMore: Bool }
struct TrackRange { var points: [TrackPoint]; var total: Int64; var truncated: Bool }

enum StoreError: Error { case sqlite(String) }

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The background writer and screen share one SQLite owner. Schema matches the Android app.
final class LocationTrackerStore {
  static let maxRecords = 80_000
  private static let trim = "DELETE FROM phone_locations WHERE id IN (SELECT id FROM phone_locations ORDER BY recorded_at DESC,id DESC LIMIT -1 OFFSET \(maxRecords))"
  private static var instance: LocationTrackerStore?
  private static let instanceLock = NSLock()

  static func shared() throws -> LocationTrackerStore {
    instanceLock.lock(); defer { instanceLock.unlock() }
    if let instance { return instance }
    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let store = try LocationTrackerStore(path: directory.appendingPathComponent("phonetracker.sqlite").path)
    instance = store
    return store
  }

  private var db: OpaquePointer?
  private let lock = NSLock()
  /// Injected for tests; production uses the wall clock like Android's System.currentTimeMillis().
  var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

  init(path: String) throws {
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close(db); db = nil
      throw StoreError.sqlite(message)
    }
    try exec("PRAGMA journal_mode=WAL")
    let version = try scalar("PRAGMA user_version", [])
    if version < 1 {
      try exec("""
        CREATE TABLE IF NOT EXISTS phone_locations (
        id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL, location_at INTEGER NOT NULL,
        latitude REAL NOT NULL, longitude REAL NOT NULL, raw_latitude REAL NOT NULL, raw_longitude REAL NOT NULL,
        accuracy_meters REAL NOT NULL, altitude_meters REAL, speed_kmh REAL, raw_speed_kmh REAL,
        heading_degrees REAL, speed_accuracy_mps REAL, motion_state TEXT NOT NULL, session_id TEXT NOT NULL,
        display_latitude REAL NOT NULL, display_longitude REAL NOT NULL, display_source TEXT NOT NULL,
        display_location_at INTEGER NOT NULL)
        """)
      try exec("CREATE INDEX IF NOT EXISTS idx_phone_location_time ON phone_locations(recorded_at,id)")
    }
    if version < 2 { try exec(Self.trim); try exec("PRAGMA user_version=2") }
  }

  deinit { sqlite3_close(db) }

  func save(_ location: LocationSample, session: String, display: DisplayLocation? = nil) throws {
    lock.lock(); defer { lock.unlock() }
    let values: [Any?] = [
      clock(), location.timestamp, location.latitude, location.longitude, location.rawLatitude, location.rawLongitude,
      Double(location.accuracy), location.altitude, location.speed.map { Double($0) * 3.6 },
      location.rawSpeed.map { Double($0) * 3.6 }, location.bearing.map { Double($0) }, location.speedAccuracy.map { Double($0) },
      location.motionState, session, display?.latitude ?? location.latitude, display?.longitude ?? location.longitude,
      display == nil ? "pipeline" : "animated", display?.fixTime ?? location.timestamp,
    ]
    try exec("BEGIN IMMEDIATE")
    do {
      try run("""
        INSERT INTO phone_locations (recorded_at,location_at,latitude,longitude,raw_latitude,raw_longitude,
        accuracy_meters,altitude_meters,speed_kmh,raw_speed_kmh,heading_degrees,speed_accuracy_mps,motion_state,
        session_id,display_latitude,display_longitude,display_source,display_location_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, values)
      try exec(Self.trim)
      try exec("COMMIT")
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  func count(since: Int64 = 0, until: Int64 = .max) throws -> Int64 {
    lock.lock(); defer { lock.unlock() }
    return try scalar("SELECT count(*) FROM phone_locations WHERE recorded_at>=? AND recorded_at<?", [since, until])
  }

  func page(before: Int64 = 0) throws -> TrackPage {
    let points = try query(before > 0 ? "WHERE id<?" : "", before > 0 ? [before] : [], order: "id DESC", limit: 51)
    return TrackPage(points: Array(points.prefix(50)), total: try count(), hasMore: points.count > 50)
  }

  func range(since: Int64, until: Int64) throws -> TrackRange {
    precondition(since < until)
    // Bound screen memory; the database retains up to maxRecords points.
    let points = try query("WHERE recorded_at>=? AND recorded_at<?", [since, until], order: "recorded_at DESC,id DESC", limit: 8001)
    return TrackRange(points: Array(points.prefix(8000).reversed()), total: try count(since: since, until: until),
                      truncated: points.count > 8000)
  }

  private func query(_ whereClause: String, _ args: [Any?], order: String, limit: Int) throws -> [TrackPoint] {
    lock.lock(); defer { lock.unlock() }
    let statement = try prepare("SELECT id,recorded_at,display_latitude,display_longitude,accuracy_meters,speed_kmh,session_id,motion_state FROM phone_locations \(whereClause) ORDER BY \(order) LIMIT \(limit)", args)
    defer { sqlite3_finalize(statement) }
    var output: [TrackPoint] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw error() }
      output.append(TrackPoint(
        id: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1),
        latitude: sqlite3_column_double(statement, 2), longitude: sqlite3_column_double(statement, 3),
        accuracy: sqlite3_column_double(statement, 4),
        speed: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5),
        session: String(cString: sqlite3_column_text(statement, 6)), motion: String(cString: sqlite3_column_text(statement, 7))))
    }
    return output
  }

  private func error() -> StoreError { .sqlite(String(cString: sqlite3_errmsg(db))) }

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }

  private func run(_ sql: String, _ args: [Any?]) throws {
    let statement = try prepare(sql, args)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
  }

  private func scalar(_ sql: String, _ args: [Any?]) throws -> Int64 {
    let statement = try prepare(sql, args)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
    return sqlite3_column_int64(statement, 0)
  }

  private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
    for (offset, value) in args.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case let value as Int64: sqlite3_bind_int64(statement, index, value)
      case let value as Double: sqlite3_bind_double(statement, index, value)
      case let value as String: sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
      default: sqlite3_bind_null(statement, index)
      }
    }
    return statement
  }
}
