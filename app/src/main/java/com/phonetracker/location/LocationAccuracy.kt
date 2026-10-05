package com.phonetracker.location

internal fun isFastLocation(speed: Float?): Boolean =
  speed != null && speed.isFinite() && speed > 20f / 3.6f

internal fun acceptsLocationAccuracy(hasAccuracy: Boolean, meters: Float, speed: Float? = null): Boolean =
  hasAccuracy && meters.isFinite() && meters >= 0f &&
    (if (isFastLocation(speed)) meters < 50f else meters <= 30f)
