package com.phonetracker.location

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

data class TrackPoint(val id: Long, val time: Long, val latitude: Double, val longitude: Double,
    val accuracy: Double, val speed: Double?, val session: String, val motion: String)
data class TrackPage(val points: List<TrackPoint>, val total: Long, val hasMore: Boolean)
data class TrackRange(val points: List<TrackPoint>, val total: Long, val truncated: Boolean)

/** The background writer and screen share one SQLite owner, separate from DogTracker. */
class LocationTrackerStore private constructor(context: Context) : SQLiteOpenHelper(context, "phonetracker.sqlite", null, 1) {
    companion object {
        @Volatile private var instance: LocationTrackerStore? = null
        fun get(context: Context): LocationTrackerStore = instance ?: synchronized(this) {
            instance ?: LocationTrackerStore(context.applicationContext).also { instance = it }
        }
        private const val TRIM = "DELETE FROM phone_locations WHERE id IN (SELECT id FROM phone_locations ORDER BY recorded_at DESC,id DESC LIMIT -1 OFFSET 80000)"
    }
    override fun onConfigure(db: SQLiteDatabase) { db.enableWriteAheadLogging() }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""CREATE TABLE phone_locations (
            id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL, location_at INTEGER NOT NULL,
            latitude REAL NOT NULL, longitude REAL NOT NULL, raw_latitude REAL NOT NULL, raw_longitude REAL NOT NULL,
            accuracy_meters REAL NOT NULL, altitude_meters REAL, speed_kmh REAL, raw_speed_kmh REAL,
            heading_degrees REAL, speed_accuracy_mps REAL, motion_state TEXT NOT NULL, session_id TEXT NOT NULL,
            display_latitude REAL NOT NULL, display_longitude REAL NOT NULL, display_source TEXT NOT NULL,
            display_location_at INTEGER NOT NULL)""")
        db.execSQL("CREATE INDEX idx_phone_location_time ON phone_locations(recorded_at,id)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    @Synchronized internal fun save(location: LocationSample, session: String, display: DisplayLocation? = null) {
        val values = ContentValues().apply {
            put("recorded_at", System.currentTimeMillis()); put("location_at", location.timestamp)
            put("latitude", location.latitude); put("longitude", location.longitude)
            put("raw_latitude", location.rawLatitude); put("raw_longitude", location.rawLongitude)
            put("accuracy_meters", location.accuracy); put("altitude_meters", location.altitude)
            put("speed_kmh", location.speed?.times(3.6)); put("raw_speed_kmh", location.rawSpeed?.times(3.6))
            put("heading_degrees", location.bearing); put("speed_accuracy_mps", location.speedAccuracy)
            put("motion_state", location.motionState); put("session_id", session)
            put("display_latitude", display?.latitude ?: location.latitude)
            put("display_longitude", display?.longitude ?: location.longitude)
            put("display_source", if (display == null) "pipeline" else "animated")
            put("display_location_at", display?.fixTime ?: location.timestamp)
        }
        writableDatabase.beginTransaction()
        try {
            writableDatabase.insertOrThrow("phone_locations", null, values)
            writableDatabase.execSQL(TRIM)
            writableDatabase.setTransactionSuccessful()
        } finally { writableDatabase.endTransaction() }
    }
    private fun query(where: String, args: Array<String>, order: String, limit: Int): List<TrackPoint> {
        val output = mutableListOf<TrackPoint>()
        readableDatabase.rawQuery("SELECT id,recorded_at,display_latitude,display_longitude,accuracy_meters,speed_kmh,session_id,motion_state FROM phone_locations $where ORDER BY $order LIMIT $limit", args).use { cursor ->
            while (cursor.moveToNext()) output.add(TrackPoint(cursor.getLong(0), cursor.getLong(1), cursor.getDouble(2),
                cursor.getDouble(3), cursor.getDouble(4), if (cursor.isNull(5)) null else cursor.getDouble(5), cursor.getString(6), cursor.getString(7)))
        }
        return output
    }
    @Synchronized fun count(since: Long = 0, until: Long = Long.MAX_VALUE): Long =
        readableDatabase.rawQuery("SELECT count(*) FROM phone_locations WHERE recorded_at>=? AND recorded_at<?", arrayOf(since.toString(), until.toString())).use { it.moveToFirst(); it.getLong(0) }
    @Synchronized fun page(before: Long = 0): TrackPage {
        val points = query(if (before > 0) "WHERE id<?" else "", if (before > 0) arrayOf(before.toString()) else emptyArray(), "id DESC", 51)
        return TrackPage(points.take(50), count(), points.size > 50)
    }
    @Synchronized fun range(since: Long, until: Long): TrackRange {
        require(since < until)
        // Bound screen memory; the database retains all 80,000 points.
        val points = query("WHERE recorded_at>=? AND recorded_at<?", arrayOf(since.toString(), until.toString()), "recorded_at DESC,id DESC", 8001)
        return TrackRange(points.take(8000).reversed(), count(since, until), points.size > 8000)
    }
}
