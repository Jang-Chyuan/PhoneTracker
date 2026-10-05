package com.phonetracker

import com.phonetracker.location.TrackPoint
import kotlin.math.ceil

object HistoryGeometry {
    fun segments(points: List<TrackPoint>, maxPoints: Int = 4000, maxSegments: Int = 120): List<List<TrackPoint>> {
        val segments = mutableListOf<MutableList<TrackPoint>>()
        var previous: TrackPoint? = null
        for (point in points) {
            if (!point.latitude.isFinite() || !point.longitude.isFinite() || kotlin.math.abs(point.latitude) > 90 || kotlin.math.abs(point.longitude) > 180) {
                previous = null
                continue
            }
            val last = previous
            if (last == null || point.session != last.session || point.time - last.time > 120000 || point.time < last.time
                || kotlin.math.abs(point.longitude - last.longitude) > 180) segments.add(mutableListOf())
            segments.last().add(point)
            previous = point
        }
        val visible = segments.takeLast(maxSegments)
        if (visible.sumOf { it.size } <= maxPoints) return visible
        val mandatory = visible.sumOf { minOf(2, it.size) }
        var available = (maxPoints - mandatory).coerceAtLeast(0)
        var interior = visible.sumOf { (it.size - 2).coerceAtLeast(0) }
        return visible.map { segment ->
            val inner = (segment.size - 2).coerceAtLeast(0)
            val allocation = if (interior == 0) 0 else minOf(available, ceil(available.toDouble() * inner / interior).toInt())
            available -= allocation; interior -= inner
            if (segment.size <= allocation + 2) segment else {
                val indices = (0 until allocation + 2).map { it * (segment.size - 1) / (allocation + 1) }
                indices.map { segment[it] }
            }
        }
    }
}
