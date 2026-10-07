package com.phonetracker.location

/** Map estimates never bypass the recording pipeline's accuracy checks. */
internal class LocationPreview {
  var latest: LocationSample? = null; private set
  fun accept(sample: LocationSample, now: Long): Boolean {
    if (!sample.latitude.isFinite() || !sample.longitude.isFinite() ||
      sample.latitude !in -90.0..90.0 || sample.longitude !in -180.0..180.0 ||
      !sample.accuracy.isFinite() || sample.accuracy < 0 || sample.elapsedNanos <= 0 ||
      sample.elapsedNanos > now || now - sample.elapsedNanos > 30_000_000_000L ||
      sample.elapsedNanos <= (latest?.elapsedNanos ?: 0L)) return false
    latest = sample
    return true
  }
}
