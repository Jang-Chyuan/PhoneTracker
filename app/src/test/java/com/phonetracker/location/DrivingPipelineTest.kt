package com.phonetracker.location

import org.junit.Assert.*
import org.junit.Test

class DrivingPipelineTest {
  @Test fun fastLowerPrecisionFixesProduceFreshPointsEverySecond() {
    val pipeline = LocationPipeline()
    for (t in 1L..10L) {
      val sample = point(t, t * 10.0, 36.0, 49f)
      assertTrue(pipeline.accept(sample, sample.elapsedNanos))
      val saved = pipeline.candidate(sample.elapsedNanos)!!
      assertEquals(sample.timestamp, saved.timestamp)
      assertEquals(sample.speed, saved.speed)
      pipeline.written(saved, sample.elapsedNanos)
      assertNull(pipeline.candidate(sample.elapsedNanos))
    }
  }
  private fun point(t: Long, meters: Double, kmh: Double, accuracy: Float = 3f) =
    LocationSample(25 + meters / 111195, 121.0, accuracy, t * 1_000_000_000L,
      t * 1000, (kmh / 3.6).toFloat(), speedAccuracy = 0.2f)

  @Test fun cityAndHighwayDrivingProduceAdaptiveWritesWithoutZeroing() {
    for (kmh in listOf(30.0, 60.0, 120.0)) {
      val pipeline = LocationPipeline()
      val saved = mutableListOf<LocationSample>()
      for (t in 1L..61L) {
        val sample = point(t, t * kmh / 3.6, kmh)
        assertTrue(pipeline.accept(sample, sample.elapsedNanos))
        assertEquals("moving", pipeline.latest!!.motionState)
        assertEquals(sample.speed, pipeline.latest!!.speed)
        // High-speed smoothing trails by less than 0.2 seconds of travel.
        assertTrue((sample.latitude - pipeline.latest!!.latitude) * 111195 < kmh / 3.6 * 0.2)
        pipeline.candidate(sample.elapsedNanos)?.let {
          saved.add(it); pipeline.written(it, sample.elapsedNanos)
        }
      }
      val interval = if (kmh > 20) 1 else 3
      assertEquals(60 / interval + 1, saved.size)
      assertTrue(saved.zipWithNext().all { (a, b) -> b.timestamp - a.timestamp == interval * 1000L })
      assertEquals(0, pipeline.rejected)
    }
  }

  @Test fun trafficLightDepartureUnlocksCoordinatesAndSpeedAfterThreeSeconds() {
    val pipeline = LocationPipeline()
    for (t in 1L..21L) {
      val sample = point(t, 0.0, 0.0)
      pipeline.accept(sample, sample.elapsedNanos)
    }
    assertEquals("stationary", pipeline.latest!!.motionState)
    val locked = pipeline.latest!!.latitude
    for (t in 22L..25L) {
      val sample = point(t, (t - 21) * 10.0, 36.0)
      assertTrue(pipeline.accept(sample, sample.elapsedNanos))
      if (t < 25) assertEquals(locked, pipeline.latest!!.latitude, 0.0)
      else assertTrue(pipeline.latest!!.latitude > locked)
      assertEquals(sample.rawLatitude, pipeline.latest!!.rawLatitude, 0.0)
      assertEquals(sample.rawSpeed, pipeline.latest!!.rawSpeed)
      assertEquals(if (t < 25) 0f else 10f, pipeline.latest!!.speed)
    }
    assertEquals("moving", pipeline.latest!!.motionState)
  }

  @Test fun reducedAccuracyStillRecordsAndOutageDoesNotReplayOldPositions() {
    val pipeline = LocationPipeline()
    val first = point(1, 0.0, 60.0, 20f)
    assertTrue(pipeline.accept(first, first.elapsedNanos))
    assertEquals("unknown", pipeline.latest!!.motionState)
    assertEquals(first.speed, pipeline.latest!!.speed)
    pipeline.written(pipeline.candidate(first.elapsedNanos)!!, first.elapsedNanos)
    val poor = point(6, 83.3, 60.0, 50f)
    assertFalse(pipeline.accept(poor, poor.elapsedNanos))
    assertNull(pipeline.candidate(poor.elapsedNanos))
    val recovered = point(40, 650.0, 60.0)
    assertTrue(pipeline.accept(recovered, recovered.elapsedNanos))
    assertNotNull(pipeline.candidate(recovered.elapsedNanos))
    assertEquals("moving", pipeline.latest!!.motionState)
  }
}
