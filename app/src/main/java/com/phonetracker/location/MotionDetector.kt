package com.phonetracker.location

import kotlin.math.*

/** Judges raw samples; LocationPipeline applies the stationary speed and position lock. */
internal class MotionDetector {
  private val history = java.util.ArrayDeque<LocationSample>()
  private var state = "moving"
  private var anchor: LocationSample? = null
  private var resumeSince: Long? = null
  private var lastTime = 0L
  fun accept(point: LocationSample): String {
    if (lastTime > 0 && point.elapsedNanos - lastTime > 3_000_000_000L) reset()
    lastTime = point.elapsedNanos
    val speed = point.rawSpeed
    val uncertainty = point.speedAccuracy?.takeIf { it.isFinite() && it >= 0 }
    if (speed == null || !speed.isFinite() || speed < 0 || point.accuracy > 10f) {
      reset(); return "unknown"
    }
    val credibleMovement = if (uncertainty != null) speed - uncertainty > 0.5f else speed > 1f
    val low = speed <= 1f && !credibleMovement &&
      (if (uncertainty != null) uncertainty <= 1f else speed <= 0.3f)
    if (state == "stationary") {
      val departing = distance(anchor!!, point) > max(5.0, point.accuracy.toDouble())
      if (credibleMovement || departing) {
        val start = resumeSince ?: point.elapsedNanos.also { resumeSince = it }
        if (point.elapsedNanos - start >= 3_000_000_000L) {
          reset(); return "moving"
        }
      } else {
        resumeSince = null
        if (!low) { reset(); return "unknown" }
      }
      return state
    }
    if (!low) { reset(); return if (credibleMovement) "moving" else "unknown" }
    history.addLast(point)
    while (history.size > 1 && point.elapsedNanos - history.elementAt(1).elapsedNanos >= 20_000_000_000L) history.removeFirst()
    val first = history.first
    val points = history.toList()
    val net = distance(first, point)
    val path = points.zipWithNext().sumOf { (a, b) -> distance(a, b) }
    val directional = net > 3.0 && path > 0 && net / path > 0.75
    val clustered = points.all { distance(first, it) <= 5.0 }
    if (!clustered || directional) { reset(); return "moving" }
    val seconds = (point.elapsedNanos - first.elapsedNanos) / 1e9
    state = when {
      seconds >= 20 -> "stationary"
      seconds >= 15 -> "suspected_stationary"
      else -> "moving"
    }
    if (state == "stationary") anchor = first
    return state
  }
  private fun reset() { history.clear(); state = "moving"; anchor = null; resumeSince = null }
  private fun distance(a: LocationSample, b: LocationSample): Double {
    val lat = Math.toRadians(b.rawLatitude - a.rawLatitude)
    val lon = Math.toRadians(b.rawLongitude - a.rawLongitude)
    val h = sin(lat / 2).pow(2) + cos(Math.toRadians(a.rawLatitude)) * cos(Math.toRadians(b.rawLatitude)) * sin(lon / 2).pow(2)
    return 12742000 * asin(sqrt(h.coerceIn(0.0, 1.0)))
  }
}
