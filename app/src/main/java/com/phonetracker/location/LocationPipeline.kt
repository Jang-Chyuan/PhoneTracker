package com.phonetracker.location

import kotlin.math.*

internal data class LocationSample(
  val latitude: Double, val longitude: Double, val accuracy: Float,
  val elapsedNanos: Long, val timestamp: Long, val speed: Float? = null,
  val bearing: Float? = null, val altitude: Double? = null,
  val rawLatitude: Double = latitude, val rawLongitude: Double = longitude,
  val speedAccuracy: Float? = null, val rawSpeed: Float? = speed,
  val motionState: String = "moving"
)

/** Acquisition, display and persistence have separate clocks. Never replay old fixes. */
internal class LocationPipeline {
  var latest: LocationSample? = null; private set
  var received = 0; private set
  var accepted = 0; private set
  var rejected = 0; private set
  var reason = "等待新定位"; private set
  private var lastSavedSample = 0L
  private var lastWrite = 0L
  private var newest = 0L
  private val window = java.util.ArrayDeque<LocationSample>()
  private val motion = MotionDetector()
  private var stationaryCoordinate: Pair<Double, Double>? = null
  val intervalSeconds: Int get() {
    val speed = latest?.rawSpeed?.takeIf { it.isFinite() && it >= 0 } ?: return 5
    return when {
      isFastLocation(speed) -> 1
      speed > 10f / 3.6f -> 3
      else -> 5
    }
  }
  fun accept(sample: LocationSample, now: Long): Boolean {
    received++
    fun reject(message: String): Boolean { rejected++; reason = message; return false }
    if (sample.elapsedNanos <= 0 || sample.elapsedNanos > now || now - sample.elapsedNanos > 3_000_000_000L)
      return reject("定位過期，等待新樣本")
    if (sample.elapsedNanos <= newest) return reject("略過重複或倒序定位")
    if (!sample.latitude.isFinite() || !sample.longitude.isFinite() || abs(sample.latitude) > 90 || abs(sample.longitude) > 180)
      return reject("定位座標無效")
    if (!acceptsLocationAccuracy(true, sample.accuracy, sample.rawSpeed))
      return reject(if (isFastLocation(sample.rawSpeed)) "等待合格定位（需 < 50 公尺）" else "等待合格定位（需 ≤ 30 公尺）")
    val previous = latest
    val dt = if (previous == null) 0.0 else (sample.elapsedNanos - previous.elapsedNanos) / 1e9
    val reset = previous == null || dt > 30
    if (!reset) {
      val distance = distanceMeters(previous!!.rawLatitude, previous.rawLongitude, sample.latitude, sample.longitude)
      if (distance > 70 * dt + previous.accuracy + sample.accuracy)
        return reject("略過不合理位置跳動")
    }
    // Three valid raw samples; a signal gap starts a new smoothing window.
    if (reset || dt > 3) {
      window.clear()
      stationaryCoordinate = null
    }
    window.addLast(sample)
    while (window.size > 3) window.removeFirst()
    val points = window.toList()
    val fast = sample.speed != null && sample.speed * 3.6 > 10
    val weights = if (fast && points.size > 1)
      points.indices.map { if (it == points.lastIndex) 0.9 else 0.1 / (points.size - 1) }
      else points.map { 1.0 / points.size }
    val latitude = points.indices.sumOf { points[it].latitude * weights[it] }
    val offset = points.indices.sumOf { (((points[it].longitude - sample.longitude + 540) % 360) - 180) * weights[it] }
    val state = motion.accept(sample)
    val longitude = ((sample.longitude + offset + 540) % 360) - 180
    // Lock the smoothed position at confirmation, while continuing to judge raw fixes.
    if (state == "stationary") {
      if (stationaryCoordinate == null) stationaryCoordinate = latitude to longitude
    } else stationaryCoordinate = null
    latest = sample.copy(latitude = stationaryCoordinate?.first ?: latitude,
      longitude = stationaryCoordinate?.second ?: longitude,
      speed = if (state == "stationary") 0f else sample.speed, motionState = state)
    newest = sample.elapsedNanos
    accepted++; reason = "接收與平滑中"
    return true
  }
  fun candidate(now: Long): LocationSample? {
    val value = latest ?: return null
    if (now - value.elapsedNanos > 3_000_000_000L || value.elapsedNanos <= lastSavedSample) return null
    if (lastWrite > 0 && now - lastWrite < intervalSeconds * 1_000_000_000L) return null
    return value
  }
  fun written(sample: LocationSample, now: Long) { lastSavedSample = sample.elapsedNanos; lastWrite = now }
  private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val dlat = Math.toRadians(lat2 - lat1); val dlon = Math.toRadians(lon2 - lon1)
    val a = sin(dlat / 2).pow(2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dlon / 2).pow(2)
    return 6371000 * 2 * asin(sqrt(a.coerceIn(0.0, 1.0)))
  }
}
