package com.phonetracker

import com.phonetracker.location.TrackPoint
import org.junit.Assert.*
import org.junit.Test

class HistoryGeometryTest {
    private fun point(id: Long, time: Long = id * 1000, session: String = "a", lon: Double = 121.0) =
        TrackPoint(id, time, 25.0, lon, 10.0, 0.0, session, "moving")
    @Test fun gapsAndSessionsNeverConnect() {
        val segments = HistoryGeometry.segments(listOf(point(1), point(2), point(3, 200000), point(4, 201000, "b")))
        assertEquals(listOf(2, 1, 1), segments.map { it.size })
    }
    @Test fun datelineAndInvalidLocationsBreakSegments() {
        val segments = HistoryGeometry.segments(listOf(point(1, lon = 179.9), point(2, lon = -179.9),
            point(3, lon = Double.NaN), point(4)))
        assertEquals(listOf(1, 1, 1), segments.map { it.size })
    }
    @Test fun drawingBudgetRetainsEndpointsWithoutChangingStoredPoints() {
        val points = (1L..8000L).map { point(it) }
        val output = HistoryGeometry.segments(points)
        assertEquals(4000, output.sumOf { it.size })
        assertEquals(1L, output.first().first().id)
        assertEquals(8000L, output.last().last().id)
        assertEquals(8000, points.size)
    }
}
