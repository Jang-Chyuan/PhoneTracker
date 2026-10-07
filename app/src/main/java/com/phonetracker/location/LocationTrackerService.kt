package com.phonetracker.location

import android.app.*
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.location.*
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.phonetracker.MainActivity
import com.phonetracker.R
import org.json.JSONObject
import java.util.UUID
import java.io.FileDescriptor
import java.io.PrintWriter

/** Native acquisition and storage continue without a mounted React screen. */
class LocationTrackerService : Service() {
  companion object {
    @Volatile var running = false
    @Volatile var status = "尚未開始記錄"
    @Volatile var liveJson = "{}"
    @Volatile internal var displayLocation: DisplayLocation? = null
    const val CHANNEL = "phonetracker_phone_location"
    const val ID = 3105
    const val REFRESH_NOTIFICATION = "com.phonetracker.REFRESH_NOTIFICATION"
  }
  private lateinit var manager: LocationManager
  private lateinit var fusedLocation: FusedLocationProviderClient
  private val preview = LocationPreview()
  private val locationCallback = object : LocationCallback() {
    override fun onLocationResult(result: LocationResult) {
      for (location in result.locations) acceptLocation(location)
    }
  }
  private val worker = HandlerThread("PhoneLocationWriter")
  private lateinit var handler: Handler
  private var store: LocationTrackerStore? = null
  private val pipeline = LocationPipeline()
  private val sessionId = UUID.randomUUID().toString()
  private var saved = 0
  private var writeErrors = 0
  private var wakeLock: PowerManager.WakeLock? = null
  private var wakeRenewAt = 0L
  private val tick = object : Runnable {
    override fun run() {
      if (stopped) return
      keepWriterAwake()
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
      val estimate = preview.latest
      val eligible = estimate != null && estimate.elapsedNanos == pipeline.latest?.elapsedNanos
      val latest = if (eligible) pipeline.latest else estimate
      val age = latest?.let { (now - it.elapsedNanos) / 1e9 }
      if (!writeFailed) status = when {
        age == null -> "等待融合定位"
        age > 30 -> "最後位置已過期，等待新定位"
        !eligible -> "估算位置，未寫入軌跡；${pipeline.reason}"
        age > 3 -> "等待合格新定位；最後合格位置已過期"
        else -> pipeline.reason
      }
      liveJson = JSONObject().put("running", running).put("status", status)
        .put("received", pipeline.received).put("accepted", pipeline.accepted).put("rejected", pipeline.rejected)
        .put("saved", saved).put("writeErrors", writeErrors).put("ageSeconds", age ?: JSONObject.NULL)
        .put("intervalSeconds", pipeline.intervalSeconds)
        .put("sessionId", sessionId).apply {
          if (latest != null) put("position", JSONObject().put("latitude", latest.latitude).put("longitude", latest.longitude)
            .put("recordingEligible", eligible && age != null && age <= 3)
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
    fusedLocation = LocationServices.getFusedLocationProviderClient(this)
    worker.start()
    handler = Handler(worker.looper)
    if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java)
      .createNotificationChannel(NotificationChannel(CHANNEL, "手機位置記錄", NotificationManager.IMPORTANCE_LOW))
  }
  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val preferences = getSharedPreferences("phone_location_recording", 0)
    if (intent?.action == REFRESH_NOTIFICATION) {
      if (!running || !preferences.getBoolean("enabled", true)) {
        if (!running) stopSelf()
        return START_NOT_STICKY
      }
      if (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this,
          Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
        getSystemService(NotificationManager::class.java).notify(ID, recordingNotification())
      }
      return START_STICKY
    }
    if (intent?.action == "STOP") {
      preferences.edit().putBoolean("enabled", false).apply()
      stopSelf(); return START_NOT_STICKY
    }
    // A queued automatic start must not undo a later explicit stop.
    if (!preferences.getBoolean("enabled", true)) { stopSelf(); return START_NOT_STICKY }
    if (running) return START_STICKY
    try {
      startForeground(ID, recordingNotification())
      val precise = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
      check(precise) { "請允許精確位置" }
      check(LocationManagerCompat.isLocationEnabled(manager)) { "請開啟手機定位服務" }
      val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
        .setMinUpdateIntervalMillis(1000L).setMaxUpdateDelayMillis(0L)
        .setMaxUpdateAgeMillis(0L).setWaitForAccurateLocation(false).build()
      fusedLocation.requestLocationUpdates(request, locationCallback, worker.looper)
        .addOnFailureListener {
          if (!stopped) {
            status = "無法啟動融合定位，請確認 Google Play 服務與定位權限"
            stopSelf()
          }
        }
      wakeLock = getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PhoneTracker:location-writer")
        .apply { setReferenceCounted(false) }
      keepWriterAwake()
      running = true
      status = "等待合格定位：≤ 30 m；> 20 km/h 時 < 50 m"
      handler.post(tick)
    } catch (_: Exception) {
      status = "無法開始記錄，請允許精確位置並開啟手機定位"
      stopSelf()
      return START_NOT_STICKY
    }
    return START_STICKY
  }
  private fun recordingNotification(): Notification {
    val launch = PendingIntent.getActivity(this, ID, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val stop = PendingIntent.getService(this, ID, Intent(this, javaClass).setAction("STOP"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    return NotificationCompat.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_location)
      .setContentTitle("PhoneTracker 背景位置記錄").setContentText("≤ 10 km/h 每 30 秒；> 10～20 每 5 秒；> 20 每秒保存")
      .setContentIntent(launch).setOngoing(true).setOnlyAlertOnce(true)
      .addAction(0, "停止記錄", stop).build()
  }
  private fun keepWriterAwake() {
    val lock = wakeLock ?: return
    val now = SystemClock.elapsedRealtime()
    // Renew only while recording. A timeout releases the lock if the writer stalls.
    if (!lock.isHeld || now >= wakeRenewAt) {
      lock.acquire(10 * 60_000L)
      wakeRenewAt = now + 5 * 60_000L
    }
  }
  override fun dump(fd: FileDescriptor?, writer: PrintWriter, args: Array<out String>?) {
    writer.println("PhoneTracker running=$running saved=$saved received=${pipeline.received} writeErrors=$writeErrors")
    writer.println("lastLocationAt=${pipeline.latest?.timestamp} intervalSeconds=${pipeline.intervalSeconds}")
    writer.println("wakeLockHeld=${wakeLock?.isHeld == true}")
  }
  private fun acceptLocation(location: Location) {
    if (stopped) return
    val now = SystemClock.elapsedRealtimeNanos()
    val sample = LocationSample(location.latitude, location.longitude,
      if (location.hasAccuracy()) location.accuracy else Float.NaN, location.elapsedRealtimeNanos, location.time,
      if (location.hasSpeed() && location.speed.isFinite() && location.speed >= 0) location.speed else null,
      if (location.hasBearing() && location.bearing.isFinite()) location.bearing else null,
      if (location.hasAltitude() && location.altitude.isFinite()) location.altitude else null,
      speedAccuracy = if (Build.VERSION.SDK_INT >= 26 && location.hasSpeedAccuracy() &&
        location.speedAccuracyMetersPerSecond.isFinite() && location.speedAccuracyMetersPerSecond >= 0)
        location.speedAccuracyMetersPerSecond else null)
    preview.accept(sample, now)
    if (!pipeline.accept(sample, now)) displayLocation = null
  }
  override fun onDestroy() {
    stopped = true
    handler.removeCallbacks(tick)
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
    liveJson = "{}"
    displayLocation = null
    fusedLocation.removeLocationUpdates(locationCallback)
    worker.quitSafely()
    if (running) status = "已停止記錄"
    running = false
    stopForeground(STOP_FOREGROUND_REMOVE)
    super.onDestroy()
  }
}
