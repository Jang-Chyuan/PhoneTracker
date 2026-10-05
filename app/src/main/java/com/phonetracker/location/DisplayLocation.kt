package com.phonetracker.location
import kotlin.math.*

internal data class DisplayLocation(val session: String, val fixTime: Long, val latitude: Double,
  val longitude: Double, val receivedNanos: Long) {
  fun usable(sessionId: String, sample: LocationSample, now: Long): Boolean =
    session == sessionId && sample.timestamp >= fixTime && sample.timestamp - fixTime <= 3000 &&
      now >= receivedNanos && now - receivedNanos <= 1_500_000_000L &&
      latitude.isFinite() && longitude.isFinite() &&
      distanceMeters(latitude, longitude, sample.latitude, sample.longitude) <= 300 + sample.accuracy
  private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val dlat = Math.toRadians(lat2 - lat1); val dlon = Math.toRadians(lon2 - lon1)
    val a = sin(dlat / 2).pow(2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dlon / 2).pow(2)
    return 12742000 * asin(sqrt(a.coerceIn(0.0, 1.0)))
  }
}
