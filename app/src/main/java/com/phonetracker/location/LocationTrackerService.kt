package com.phonetracker.location

import android.app.*
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.location.*
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.phonetracker.MainActivity
import com.phonetracker.R
import org.json.JSONObject
import java.util.UUID

/** Native acquisition and storage continue without a mounted React screen. */
class LocationTrackerService : Service(), LocationListener {
  companion object {
    @Volatile var running = false
    @Volatile var status = "尚未開始記錄"
    @Volatile var liveJson = "{}"
    @Volatile internal var displayLocation: DisplayLocation? = null
    const val CHANNEL = "phonetracker_phone_location"
    const val ID = 3105
  }
  private lateinit var manager: LocationManager
  private val worker = HandlerThread("PhoneLocationWriter")
  private lateinit var handler: Handler
  private var store: LocationTrackerStore? = null
  private val pipeline = LocationPipeline()
  private val sessionId = UUID.randomUUID().toString()
  private var saved = 0
  private var writeErrors = 0
  private val tick = object : Runnable {
    override fun run() {
      if (stopped) return
      val now = SystemClock.elapsedRealtimeNanos()
      val sample = pipeline.candidate(now)
      var writeFailed = false
      if (sample != null) {
        try {
          val database = store ?: LocationTrackerStore.get(this@LocationTrackerService).also { store = it }
          val display = displayLocation?.takeIf { it.usable(sessionId, sample, now) }
          database.save(sample, sessionId, display)
          pipeline.written(sample, now); saved++
        } catch (_: Exception) { writeErrors++; writeFailed = true; status = "Timeline 寫入失敗，下一秒重試" }
      }
      val latest = pipeline.latest
      val age = latest?.let { (now - it.elapsedNanos) / 1e9 }
      if (!writeFailed) status = if (age != null && age > 3) "等待合格新定位；最後位置已過期" else pipeline.reason
      liveJson = JSONObject().put("running", running).put("status", status)
        .put("received", pipeline.received).put("accepted", pipeline.accepted).put("rejected", pipeline.rejected)
        .put("saved", saved).put("writeErrors", writeErrors).put("ageSeconds", age ?: JSONObject.NULL)
        .put("intervalSeconds", pipeline.intervalSeconds)
        .put("sessionId", sessionId).apply {
          if (latest != null) put("position", JSONObject().put("latitude", latest.latitude).put("longitude", latest.longitude)
            .put("timestamp", latest.timestamp).put("accuracy", latest.accuracy)
            .put("speedKmh", latest.speed?.times(3.6) ?: JSONObject.NULL)
            .put("rawSpeedKmh", latest.rawSpeed?.times(3.6) ?: JSONObject.NULL)
            .put("speedAccuracyMps", latest.speedAccuracy ?: JSONObject.NULL)
            .put("motionState", if (age != null && age > 3) "unknown" else latest.motionState)
            .put("bearing", latest.bearing ?: JSONObject.NULL))
        }.toString()
      handler.postDelayed(this, 1000)
    }
  }
  @Volatile private var stopped = false
  override fun onBind(intent: Intent?) = null
  override fun onCreate() {
    super.onCreate()
    manager = getSystemService(LocationManager::class.java)
    worker.start()
    handler = Handler(worker.looper)
    if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java)
      .createNotificationChannel(NotificationChannel(CHANNEL, "手機位置記錄", NotificationManager.IMPORTANCE_LOW))
  }
  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val preferences = getSharedPreferences("phone_location_recording", 0)
    if (intent?.action == "STOP") {
      preferences.edit().putBoolean("enabled", false).apply()
      stopSelf(); return START_NOT_STICKY
    }
    // A queued automatic start must not undo a later explicit stop.
    if (!preferences.getBoolean("enabled", true)) { stopSelf(); return START_NOT_STICKY }
    if (running) return START_NOT_STICKY
    try {
      val launch = PendingIntent.getActivity(this, ID, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
      val stop = PendingIntent.getService(this, ID, Intent(this, javaClass).setAction("STOP"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
      startForeground(ID, NotificationCompat.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_location)
        .setContentTitle("PhoneTracker 位置記錄").setContentText("約每秒 GPS 定位；> 20 km/h 時每秒保存，精度需 < 50 m")
        .setContentIntent(launch).setOngoing(true).addAction(0, "停止記錄", stop).build())
      val precise = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
      check(precise) { "請允許精確位置" }
      val providers = listOf(LocationManager.GPS_PROVIDER).filter { manager.isProviderEnabled(it) }
      check(providers.isNotEmpty()) { "請開啟手機定位服務" }
      for (provider in providers) manager.requestLocationUpdates(provider, 1000L, 0f, this, worker.looper)
      running = true
      status = "等待合格定位：≤ 30 m；> 20 km/h 時 < 50 m"
      handler.post(tick)
    } catch (_: Exception) {
      status = "無法開始記錄，請允許精確位置並開啟 GPS"
      stopSelf()
    }
    return START_NOT_STICKY
  }
  override fun onLocationChanged(location: Location) {
    if (stopped) return
    val now = SystemClock.elapsedRealtimeNanos()
    pipeline.accept(LocationSample(location.latitude, location.longitude,
      if (location.hasAccuracy()) location.accuracy else Float.NaN, location.elapsedRealtimeNanos, location.time,
      if (location.hasSpeed() && location.speed.isFinite() && location.speed >= 0) location.speed else null,
      if (location.hasBearing() && location.bearing.isFinite()) location.bearing else null,
      if (location.hasAltitude() && location.altitude.isFinite()) location.altitude else null,
      speedAccuracy = if (Build.VERSION.SDK_INT >= 26 && location.hasSpeedAccuracy() &&
        location.speedAccuracyMetersPerSecond.isFinite() && location.speedAccuracyMetersPerSecond >= 0)
        location.speedAccuracyMetersPerSecond else null), now)
  }
  override fun onProviderDisabled(provider: String) { status = "定位來源已關閉，等待恢復" }
  override fun onProviderEnabled(provider: String) { status = "等待新定位" }
  @Deprecated("Legacy Android callback")
  override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
  override fun onDestroy() {
    stopped = true
    handler.removeCallbacks(tick)
    liveJson = "{}"
    displayLocation = null
    manager.removeUpdates(this)
    worker.quitSafely()
    if (running) status = "已停止記錄"
    running = false
    stopForeground(STOP_FOREGROUND_REMOVE)
    super.onDestroy()
  }
}
