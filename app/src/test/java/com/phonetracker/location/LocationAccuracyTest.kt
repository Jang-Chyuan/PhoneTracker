package com.phonetracker.location

import org.junit.Assert.*
import org.junit.Test

class LocationAccuracyTest {
  @Test fun fastSpeedAllowsOnlyAccuracyStrictlyBelowFifty() {
    assertFalse(acceptsLocationAccuracy(true, 40f, 20f / 3.6f))
    assertTrue(acceptsLocationAccuracy(true, 49.99f, 20.1f / 3.6f))
    assertFalse(acceptsLocationAccuracy(true, 50f, 30f))
    for (speed in listOf(null, -1f, Float.NaN, Float.POSITIVE_INFINITY))
      assertFalse(acceptsLocationAccuracy(true, 40f, speed))
  }
  @Test fun acceptsBoundaryAndBetterFixes() {
    assertTrue(acceptsLocationAccuracy(true, 5f))
    assertTrue(acceptsLocationAccuracy(true, 30f))
    assertTrue(acceptsLocationAccuracy(true, 2.5f))
  }
  @Test fun rejectsPoorMissingAndInvalidAccuracy() {
    for (meters in listOf(30.001f, 100f, -1f, Float.NaN, Float.POSITIVE_INFINITY))
      assertFalse(acceptsLocationAccuracy(true, meters))
    assertFalse(acceptsLocationAccuracy(false, 0f))
  }
}
