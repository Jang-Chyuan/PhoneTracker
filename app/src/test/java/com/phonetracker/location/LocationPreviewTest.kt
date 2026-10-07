package com.phonetracker.location

import org.junit.Assert.*
import org.junit.Test

class LocationPreviewTest {
  @Test fun indoorEstimateDisplaysWithoutBecomingARecordingCandidate() {
    val preview = LocationPreview()
    val pipeline = LocationPipeline()
    val indoor = LocationSample(25.0, 121.0, 150f, 10_000_000_000L, 10000)
    assertTrue(preview.accept(indoor, indoor.elapsedNanos))
    assertFalse(pipeline.accept(indoor, indoor.elapsedNanos))
    assertEquals(indoor, preview.latest)
    assertNull(pipeline.candidate(indoor.elapsedNanos))

    val precise = indoor.copy(accuracy = 10f, elapsedNanos = 11_000_000_000L, timestamp = 11000)
    assertTrue(preview.accept(precise, precise.elapsedNanos))
    assertTrue(pipeline.accept(precise, precise.elapsedNanos))
    assertNotNull(pipeline.candidate(precise.elapsedNanos))

    val uncertain = indoor.copy(elapsedNanos = 15_000_000_000L, timestamp = 15000)
    assertTrue(preview.accept(uncertain, uncertain.elapsedNanos))
    assertFalse(pipeline.accept(uncertain, uncertain.elapsedNanos))
    assertEquals(uncertain, preview.latest)
    assertNull(pipeline.candidate(uncertain.elapsedNanos))
  }

  @Test fun rejectsInvalidStaleFutureAndOutOfOrderEstimates() {
    val preview = LocationPreview()
    val now = 40_000_000_000L
    val sample = LocationSample(25.0, 121.0, 200f, now, 40000)
    assertFalse(preview.accept(sample.copy(latitude = 91.0), now))
    assertFalse(preview.accept(sample.copy(longitude = Double.NaN), now))
    assertFalse(preview.accept(sample.copy(accuracy = Float.NaN), now))
    assertFalse(preview.accept(sample.copy(accuracy = -1f), now))
    assertFalse(preview.accept(sample.copy(elapsedNanos = now + 1), now))
    assertFalse(preview.accept(sample.copy(elapsedNanos = 1), now))
    assertTrue(preview.accept(sample, now))
    assertFalse(preview.accept(sample, now))
    assertFalse(preview.accept(sample.copy(elapsedNanos = now - 1), now))
    assertEquals(sample, preview.latest)
  }
}
