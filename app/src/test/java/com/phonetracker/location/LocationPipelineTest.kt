package com.phonetracker.location

import org.junit.Assert.*
import org.junit.Test

class LocationPipelineTest {
  private fun sample(second: Long, lat: Double = 25.0, speed: Float? = 0f, accuracy: Float = 10f) =
    LocationSample(lat, 121.0, accuracy, second * 1_000_000_000L, second * 1000, speed)
  @Test fun threePointsAndHighSpeedWeight() {
    val slow = LocationPipeline(); val fast = LocationPipeline()
    for (i in 1L..3L) {
      slow.accept(sample(i, 25 + i * 0.00001), i * 1_000_000_000L)
      fast.accept(sample(i, 25 + i * 0.00001, 5f), i * 1_000_000_000L)
    }
    assertEquals(25.00002, slow.latest!!.latitude, 1e-8)
    assertTrue(fast.latest!!.latitude > slow.latest!!.latitude)
    assertEquals(25.00003, slow.latest!!.rawLatitude, 1e-8)
    assertEquals(10f, slow.latest!!.accuracy)
  }
  @Test fun writesEveryFiveSecondsAndNeverReplaysAnOldFix() {
    val pipe = LocationPipeline()
    for (i in 1L..11L) {
      val now = i * 1_000_000_000L
      pipe.accept(sample(i), now)
      val candidate = pipe.candidate(now)
      if (i in listOf(1L, 6L, 11L)) { assertNotNull(candidate); pipe.written(candidate!!, now) }
      else assertNull(candidate)
    }
    assertNull(pipe.candidate(20_000_000_000L))
  }
  @Test fun adaptiveBoundariesAccelerationAndDeceleration() {
    for ((kmh, interval) in listOf(0f to 5, 10f to 5, 10.1f to 3, 20f to 3, 20.1f to 1, 60f to 1)) {
      val pipe = LocationPipeline()
      pipe.accept(sample(1, speed = kmh / 3.6f), 1_000_000_000L)
      assertEquals(interval, pipe.intervalSeconds)
    }
    val pipe = LocationPipeline()
    for (i in 1L..21L) pipe.accept(sample(i, speed = 0f), i * 1_000_000_000L)
    pipe.written(pipe.candidate(21_000_000_000L)!!, 21_000_000_000L)
    pipe.accept(sample(22, speed = 30f), 22_000_000_000L)
    // Departure is still in the stationary grace period, but raw speed controls writes.
    assertEquals(0f, pipe.latest!!.speed)
    assertEquals(1, pipe.intervalSeconds)
    val fast = pipe.candidate(22_000_000_000L)!!
    pipe.written(fast, 22_000_000_000L)
    assertNull(pipe.candidate(23_000_000_000L)) // Never duplicate the saved sample.
    pipe.accept(sample(23, speed = 0f), 23_000_000_000L)
    assertEquals(5, pipe.intervalSeconds)
    assertNull(pipe.candidate(23_000_000_000L))
    pipe.accept(sample(27, speed = null), 27_000_000_000L)
    assertEquals(5, pipe.intervalSeconds)
    assertNotNull(pipe.candidate(27_000_000_000L))
  }
  @Test fun rejectsBadAccuracyStaleAndJumpingFixesWithoutConsumingWriteSlot() {
    val pipe = LocationPipeline()
    assertFalse(pipe.accept(sample(1, accuracy = 31f), 1_000_000_000L))
    assertFalse(pipe.accept(sample(1), 5_000_000_000L))
    assertTrue(pipe.accept(sample(6, accuracy = 30f), 6_000_000_000L))
    assertFalse(pipe.accept(sample(7, lat = 26.0), 7_000_000_000L))
    assertNotNull(pipe.candidate(7_000_000_000L))
    assertEquals(3, pipe.rejected)
    // Long outages reset rather than dragging the old location forward.
    assertTrue(pipe.accept(sample(50, lat = 26.0), 50_000_000_000L))
    assertEquals(26.0, pipe.latest!!.latitude, 0.0)
  }
}
