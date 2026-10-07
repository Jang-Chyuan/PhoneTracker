package com.phonetracker

import android.Manifest
import android.animation.ValueAnimator
import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.LayerDrawable
import android.location.LocationManager
import android.os.*
import android.provider.Settings
import android.view.View
import android.view.Gravity
import android.view.WindowInsets
import android.widget.*
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import com.google.android.gms.maps.*
import com.google.android.gms.maps.model.*
import com.phonetracker.location.*
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val blue = Color.rgb(37, 99, 235)
    private val ink = Color.rgb(30, 41, 59)
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var mapView: MapView
    private var map: GoogleMap? = null
    private lateinit var statusText: TextView
    private lateinit var detailText: TextView
    private lateinit var startButton: Button
    private lateinit var backgroundButton: Button
    private lateinit var filters: LinearLayout
    private lateinit var playback: LinearLayout
    private lateinit var slider: SeekBar
    private lateinit var playbackLabel: TextView
    private lateinit var playButton: Button
    private lateinit var records: LinearLayout
    private lateinit var recordsScroll: ScrollView
    private val rangeButtons = mutableMapOf<Long, Button>()
    private lateinit var customRangeButton: Button
    private lateinit var root: LinearLayout
    private lateinit var backButton: Button
    private val tabButtons = mutableMapOf<String, Button>()
    private val navigationStack = arrayListOf<String>()
    private val backCallback = android.window.OnBackInvokedCallback { navigateBack() }
    private var marker: Marker? = null
    private var historyCursor: Marker? = null
    private var cursorPoint: TrackPoint? = null
    private var cursorDragging = false
    private var cursorPoints = emptyList<TrackPoint>()
    private var cursorIcon: BitmapDescriptor? = null
    private var circle: Circle? = null
    private val lines = mutableListOf<Polyline>()
    private var animator: ValueAnimator? = null
    private var mode = "live"
    private var following = true
    private var resumed = false
    private var destroyed = false
    private var queryVersion = 0
    private var hours = 6L
    private var customStart: Long? = null
    private var customEnd: Long? = null
    private var history = emptyList<TrackPoint>()
    private var historyTotal = 0L
    private var historyTruncated = false
    private var selectedTime: Long? = null
    private var playing = false
    private var fitHistory = true
    private var lastQueryAt = 0L
    private var historyLoading = false
    private var beforeId = 0L
    private val pageStack = mutableListOf<Long>()
    private var positionTimestamp = 0L
    private var positionWasEligible = false
    private var requestStart = false
    private var waitingForNotificationPermission = false
    private val preferences by lazy { getSharedPreferences("phone_location_recording", 0) }
    private val database by lazy { LocationTrackerStore.get(this) }
    private val mapExporter by lazy { MapExporter(this) }
    private val format = SimpleDateFormat("MM/dd HH:mm:ss", Locale.TAIWAN)
    private val tick = object : Runnable {
        override fun run() {
            if (!resumed || destroyed) return
            updateLive()
            if (mode == "history") {
                if (playing && history.isNotEmpty()) {
                    val next = (selectedTime ?: history.first().time) + 60000
                    selectedTime = minOf(next, history.last().time)
                    if (next >= history.last().time) playing = false
                    drawHistory()
                } else if (selectedTime == null && !cursorDragging && !historyLoading && System.currentTimeMillis() - lastQueryAt > 10000) loadHistory()
            } else if (mode == "records" && beforeId == 0L && System.currentTimeMillis() - lastQueryAt > 10000) loadRecords()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        waitingForNotificationPermission = savedInstanceState?.getBoolean("waiting_notification", false) ?: false
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
        mapExporter.restoreState(savedInstanceState)
        hours = savedInstanceState?.getLong("hours", 6) ?: 6
        customStart = savedInstanceState?.getLong("start")?.takeIf { it > 0 }
        customEnd = savedInstanceState?.getLong("end")?.takeIf { it > 0 }
        savedInstanceState?.getStringArrayList("navigation")?.let { navigationStack.addAll(it) }
        val screenBackground = LayerDrawable(arrayOf(
            ColorDrawable(Color.rgb(248, 250, 252)), ColorDrawable(blue)
        )).apply {
            setLayerGravity(1, Gravity.BOTTOM)
            setLayerHeight(1, 0)
        }
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = screenBackground
        }
        root.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                screenBackground.setLayerHeight(1, bars.bottom)
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                screenBackground.setLayerHeight(1, insets.systemWindowInsetBottom)
            }
            insets
        }
        val heading = row()
        backButton = button("返回") { navigateBack() }
        heading.addView(backButton)
        heading.addView(text("PhoneTracker", 24).apply { setTypeface(null, Typeface.BOLD); setPadding(dp(18), dp(12), dp(18), dp(4)) }, weight())
        root.addView(heading)
        statusText = text("等待定位", 14).apply { setPadding(dp(18), 0, dp(18), dp(6)) }
        root.addView(statusText)
        val controls = row()
        startButton = button("開始記錄") { toggleRecording() }
        controls.addView(startButton, weight())
        backgroundButton = button("背景執行") {
            if (LocationTrackerService.running) finishAndRemoveTask()
            else Toast.makeText(this, "請先開始記錄，再切換到背景執行", Toast.LENGTH_SHORT).show()
        }
        controls.addView(backgroundButton, weight())
        root.addView(controls)
        filters = row()
        for (duration in listOf(1L, 3L, 6L)) {
            val range = button("${duration} 小時") { selectRange(duration) }
            range.contentDescription = "最近 $duration 小時"
            rangeButtons[duration] = range
            filters.addView(range, weight())
        }
        customRangeButton = button("指定起訖") { chooseCustomRange() }
        filters.addView(customRangeButton, weight())
        root.addView(filters)
        detailText = text("允許精確定位並開啟 GPS 後開始記錄", 12).apply { setPadding(dp(18), dp(6), dp(18), dp(6)) }
        root.addView(detailText)
        mapView = MapView(this)
        mapView.onCreate(savedInstanceState?.getBundle("map"))
        root.addView(mapView, LinearLayout.LayoutParams(-1, 0, 1f))
        recordsScroll = ScrollView(this)
        records = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), 0, dp(16), dp(10)) }
        recordsScroll.addView(records)
        root.addView(recordsScroll, LinearLayout.LayoutParams(-1, 0, 1f))
        playback = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), 0, dp(12), 0) }
        playbackLabel = text("尚無歷史資料", 12)
        playback.addView(playbackLabel)
        val playbackRow = row()
        playButton = button("播放") {
            if (history.isNotEmpty()) {
                playing = !playing
                if (playing && (selectedTime == null || selectedTime!! >= history.last().time)) selectedTime = history.first().time
                drawHistory()
            }
        }
        playbackRow.addView(playButton)
        slider = SeekBar(this).apply { max = 1000; contentDescription = "歷史回放時間" }
        playbackRow.addView(slider, weight())
        playbackRow.addView(button("完整軌跡") { playing = false; selectedTime = null; drawHistory() })
        playback.addView(playbackRow)
        slider.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(seekBar: SeekBar?) { playing = false }
            override fun onStopTrackingTouch(seekBar: SeekBar?) = Unit
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (fromUser && history.isNotEmpty()) {
                    selectedTime = history.first().time + (history.last().time - history.first().time) * progress / 1000
                    drawHistory()
                }
            }
        })
        root.addView(playback)
        val tabs = row()
        for ((id, title) in listOf("live" to "即時位置", "history" to "歷史軌跡", "export" to "匯出地圖")) {
            val tab = button(title) {
                if (id == "export") exportMap()
                else {
                    if (id == "live") { following = true; positionTimestamp = 0 }
                    if (id != mode) { navigationStack.add(mode); switchMode(id) }
                    else if (id == "live") updateLive()
                }
            }
            tabButtons[id] = tab
            tabs.addView(tab, weight())
        }
        root.addView(tabs, 3, LinearLayout.LayoutParams(-1, dp(56)))
        setContentView(root)
        root.requestApplyInsets()
        mapView.getMapAsync { googleMap ->
            map = googleMap
            googleMap.uiSettings.isMapToolbarEnabled = false
            googleMap.uiSettings.isZoomControlsEnabled = true
            googleMap.setOnCameraMoveStartedListener { reason ->
                if (reason == GoogleMap.OnCameraMoveStartedListener.REASON_GESTURE) following = false
            }
            googleMap.setOnMarkerClickListener { clicked ->
                if (mode == "history") {
                    clicked.hideInfoWindow()
                    cursorPoint?.let { playbackLabel.text = "標定時間 ${cursorTime(it)}" }
                    true
                } else false
            }
            googleMap.setOnMarkerDragListener(object : GoogleMap.OnMarkerDragListener {
                override fun onMarkerDragStart(dragged: Marker) {
                    if (dragged != historyCursor) return
                    cursorDragging = true; playing = false
                    playButton.text = "播放"
                    dragged.hideInfoWindow()
                }
                override fun onMarkerDrag(dragged: Marker) {
                    if (dragged == historyCursor) snapHistoryCursor(dragged, false)
                }
                override fun onMarkerDragEnd(dragged: Marker) {
                    if (dragged != historyCursor) return
                    snapHistoryCursor(dragged, true)
                    cursorDragging = false
                }
            })
            googleMap.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(23.7, 121.0), 7f))
            if (mode == "history") drawHistory() else updateLive()
        }
        navigationStack.removeAll { it != "live" && it != "history" }
        switchMode(savedInstanceState?.getString("mode")?.takeIf { it == "live" || it == "history" } ?: "live")
    }

    private fun switchMode(next: String) {
        queryVersion++; historyLoading = false; mode = next; playing = false; selectedTime = null
        tabButtons.forEach { (id, tab) ->
            tab.isSelected = id == mode
            tab.setTextColor(if (id == mode) Color.WHITE else blue)
            (tab.background as GradientDrawable).setColor(if (id == mode) blue else Color.rgb(239, 246, 255))
        }
        backButton.visibility = if (navigationStack.isNotEmpty() || mode != "live") View.VISIBLE else View.GONE
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(backCallback)
            if (navigationStack.isNotEmpty() || mode != "live")
                onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, backCallback)
        }
        animator?.cancel(); animator = null
        cursorPoint = null; cursorDragging = false; cursorPoints = emptyList()
        clearMap()
        mapView.visibility = if (mode == "records") View.GONE else View.VISIBLE
        recordsScroll.visibility = if (mode == "records") View.VISIBLE else View.GONE
        filters.visibility = if (mode == "history") View.VISIBLE else View.GONE
        playback.visibility = if (mode == "history") View.VISIBLE else View.GONE
        lastQueryAt = 0
        updateRangeButtons()
        when (mode) {
            "history" -> { fitHistory = true; loadHistory() }
            "records" -> { beforeId = 0; pageStack.clear(); loadRecords() }
            else -> { positionTimestamp = 0; updateLive() }
        }
    }
    private fun navigateBack() {
        if (navigationStack.isNotEmpty()) switchMode(navigationStack.removeAt(navigationStack.lastIndex))
        else if (mode != "live") switchMode("live")
        else finish()
    }
    private fun exportMap() {
        val googleMap = map
        if (googleMap == null || historyLoading || cursorDragging) {
            Toast.makeText(this, "請等待地圖載入完成後再匯出", Toast.LENGTH_SHORT).show()
            return
        }
        if (mapExporter.busy) return
        playing = false
        playButton.text = "播放"
        val caption = listOf("PhoneTracker · ${if (mode == "history") "歷史軌跡" else "即時位置"}",
            detailText.text.toString(), if (mode == "history") playbackLabel.text.toString() else "")
            .filter { it.isNotBlank() }.joinToString("\n")
        mapExporter.capture(googleMap, caption)
    }
    @Deprecated("Android activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        mapExporter.onActivityResult(requestCode, resultCode, data)
    }
    @Suppress("DEPRECATION")
    override fun onBackPressed() { navigateBack() }
    private fun toggleRecording() {
        if (LocationTrackerService.running) {
            preferences.edit().putBoolean("enabled", false).apply()
            stopService(Intent(this, LocationTrackerService::class.java))
            updateLive()
        } else ensureLocation(true)
    }
    private fun ensureLocation(manual: Boolean) {
        if (!resumed || waitingForNotificationPermission || LocationTrackerService.running || (!manual && !preferences.getBoolean("enabled", true))) return
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            if (manual || !preferences.getBoolean("asked_permission", false)) {
                requestStart = true
                preferences.edit().putBoolean("asked_permission", true).apply()
                requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), 10)
            }
            return
        }
        val manager = getSystemService(LocationManager::class.java)
        if (!LocationManagerCompat.isLocationEnabled(manager)) {
            if (manual) AlertDialog.Builder(this).setTitle("請開啟定位").setMessage("手機位置記錄需要精確位置與手機定位服務。")
                .setPositiveButton("開啟設定") { _, _ -> startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) }
                .setNegativeButton("取消", null).show()
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            && !preferences.getBoolean("asked_notification", false)) {
            preferences.edit().putBoolean("asked_notification", true).apply()
            if (manual) preferences.edit().putBoolean("enabled", true).apply()
            waitingForNotificationPermission = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 11)
            return
        }
        if (manual) preferences.edit().putBoolean("enabled", true).apply()
        try { ContextCompat.startForegroundService(this, Intent(this, LocationTrackerService::class.java)) }
        catch (_: Exception) { Toast.makeText(this, "無法開始記錄，請確認定位權限", Toast.LENGTH_LONG).show() }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 11) {
            waitingForNotificationPermission = false
            ensureLocation(false)
            refreshRecordingNotification()
        }
        if (requestCode == 10 && requestStart) {
            requestStart = false
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) ensureLocation(true)
            else Toast.makeText(this, "請允許精確位置，僅概略位置無法記錄", Toast.LENGTH_LONG).show()
        }
    }
    private fun refreshRecordingNotification() {
        if (!resumed || !LocationTrackerService.running ||
            (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)) return
        startService(Intent(this, LocationTrackerService::class.java).setAction(LocationTrackerService.REFRESH_NOTIFICATION))
    }
    private fun updateLive() {
        if (destroyed) return
        startButton.text = if (LocationTrackerService.running) "停止記錄" else "開始記錄"
        startButton.contentDescription = startButton.text
        backgroundButton.isEnabled = LocationTrackerService.running
        backgroundButton.alpha = if (backgroundButton.isEnabled) 1f else 0.45f
        statusText.text = (if (LocationTrackerService.running) "● 記錄中 · " else "○ ") + LocationTrackerService.status
        if (mode != "live") return
        val live = try { JSONObject(LocationTrackerService.liveJson) } catch (_: Exception) { JSONObject() }
        val position = live.optJSONObject("position")
        if (position == null) {
            positionWasEligible = false
            detailText.text = if (!LocationTrackerService.running) "即時位置尚未啟動，請按「開始記錄」取得手機位置"
                else if (!BuildConfig.GOOGLE_MAPS_CONFIGURED) "尚未設定 Google Maps 金鑰；GPS 記錄仍可使用"
                else "等待融合定位 · 軌跡精度需 ≤ 30 m，高速需 < 50 m"
            return
        }
        val age = live.optDouble("ageSeconds", Double.POSITIVE_INFINITY)
        val recordingEligible = position.optBoolean("recordingEligible")
        if (!recordingEligible) LocationTrackerService.displayLocation = null
        val speed = position.optDouble("speedKmh", Double.NaN)
        detailText.text = "${format.format(Date(position.optLong("timestamp")))} · 精度 ${position.optDouble("accuracy").toInt()} m · " +
            (if (speed.isFinite()) String.format(Locale.TAIWAN, "%.1f km/h", speed) else "速度未知") +
            "\n已保存 ${live.optInt("saved")} 筆 · 間隔 ${live.optInt("intervalSeconds", 30)} 秒" +
            (if (recordingEligible) " · 合格定位" else " · 估算位置，未寫入軌跡") +
            (if (age > 30) " · 最後位置已過期" else "")
        val googleMap = map ?: return
        val target = LatLng(position.getDouble("latitude"), position.getDouble("longitude"))
        if (marker == null) marker = googleMap.addMarker(MarkerOptions().position(target).title("手機位置")
            .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE)))
        marker?.alpha = if (age > 30) 0.45f else 1f
        marker?.snippet = "${format.format(Date(position.optLong("timestamp")))} · 精度 ${position.optDouble("accuracy").toInt()} m"
        val stamp = position.optLong("timestamp")
        if (stamp != positionTimestamp) {
            positionTimestamp = stamp
            animator?.cancel()
            // An indoor estimate must not enter saved coordinates through map animation.
            val origin = if (recordingEligible && positionWasEligible) marker?.position ?: target else target
            positionWasEligible = recordingEligible
            val longitudeDelta = ((target.longitude - origin.longitude + 540) % 360) - 180
            val session = live.optString("sessionId")
            animator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 900
                addUpdateListener { animation ->
                    val fraction = (animation.animatedValue as Float).toDouble()
                    val coordinate = LatLng(origin.latitude + (target.latitude - origin.latitude) * fraction,
                        origin.longitude + longitudeDelta * fraction)
                    marker?.position = coordinate
                    if (resumed && age <= 3 && recordingEligible) LocationTrackerService.displayLocation = DisplayLocation(session, stamp,
                        coordinate.latitude, coordinate.longitude, SystemClock.elapsedRealtimeNanos())
                }
                start()
            }
            if (circle == null) circle = googleMap.addCircle(CircleOptions().center(target).radius(position.optDouble("accuracy"))
                .strokeColor(0x552563EB).fillColor(0x182563EB).strokeWidth(2f))
            circle?.center = target; circle?.radius = position.optDouble("accuracy")
            if (following && age <= 30) googleMap.animateCamera(CameraUpdateFactory.newLatLngZoom(target,
                if (googleMap.cameraPosition.zoom < 14) 17f else googleMap.cameraPosition.zoom))
        }
    }
    private fun selectRange(duration: Long) {
        hours = duration; customStart = null; customEnd = null; selectedTime = null; playing = false
        cursorPoint = null
        updateRangeButtons(); fitHistory = true; loadHistory()
    }
    private fun updateRangeButtons() {
        val choices = rangeButtons.map { (duration, button) -> button to (customStart == null && hours == duration) } +
            (customRangeButton to (customStart != null))
        choices.forEach { (button, selected) ->
            button.isSelected = selected
            button.setTextColor(if (selected) Color.WHITE else blue)
            (button.background as GradientDrawable).setColor(if (selected) blue else Color.rgb(239, 246, 255))
        }
    }
    private fun chooseCustomRange() {
        pickDateTime("開始時間", customStart ?: System.currentTimeMillis() - hours * 3600000) { start ->
            pickDateTime("結束時間", customEnd ?: System.currentTimeMillis()) { end ->
                if (end <= start || end - start > 240L * 3600000) {
                    Toast.makeText(this, "結束須晚於開始，最長 240 小時", Toast.LENGTH_LONG).show()
                } else {
                    customStart = start; customEnd = end; selectedTime = null; playing = false
                    cursorPoint = null
                    updateRangeButtons(); fitHistory = true; loadHistory()
                }
            }
        }
    }
    private fun pickDateTime(title: String, initial: Long, done: (Long) -> Unit) {
        val calendar = Calendar.getInstance().apply { timeInMillis = initial }
        val picker = DatePickerDialog(this, { _, year, month, day ->
            calendar.set(year, month, day)
            TimePickerDialog(this, { _, hour, minute ->
                calendar.set(Calendar.HOUR_OF_DAY, hour); calendar.set(Calendar.MINUTE, minute)
                calendar.set(Calendar.SECOND, 0); calendar.set(Calendar.MILLISECOND, 0)
                done(calendar.timeInMillis)
            }, calendar.get(Calendar.HOUR_OF_DAY), calendar.get(Calendar.MINUTE), true).show()
        }, calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH), calendar.get(Calendar.DAY_OF_MONTH))
        picker.setTitle(title); picker.show()
    }
    private fun loadHistory() {
        if (cursorDragging) return
        val version = ++queryVersion
        lastQueryAt = System.currentTimeMillis(); historyLoading = true
        val end = customEnd ?: lastQueryAt
        val start = customStart ?: end - hours * 3600000
        if (fitHistory) { history = emptyList(); clearMap(); detailText.text = "讀取歷史軌跡…" }
        worker.execute {
            try {
                val result = database.range(start, end)
                runOnUiThread {
                    if (destroyed || version != queryVersion || mode != "history") return@runOnUiThread
                    historyLoading = false
                    history = result.points; historyTotal = result.total; historyTruncated = result.truncated
                    drawHistory()
                }
            } catch (_: Exception) {
                runOnUiThread { if (!destroyed && version == queryVersion) {
                    historyLoading = false; detailText.text = "歷史讀取失敗，請重新選擇時段重試"
                } }
            }
        }
    }
    private fun drawHistory() {
        if (mode != "history" || cursorDragging) return
        val visible = if (selectedTime == null) history else history.takeWhile { it.time <= selectedTime!! }
        val now = System.currentTimeMillis()
        val end = customEnd ?: now
        val start = customStart ?: end - hours * 3600000
        detailText.text = "${format.format(Date(start))} 至 ${format.format(Date(end))}\n共 $historyTotal 筆" +
            (if (historyTruncated) " · 僅繪製最近 8,000 筆，資料庫記錄保留" else "") +
            (if (history.isEmpty()) " · 此時段沒有手機位置記錄" else "")
        playButton.text = if (playing) "暫停" else "播放"
        playButton.isEnabled = history.size > 1
        slider.isEnabled = history.size > 1
        if (history.isNotEmpty()) {
            val span = history.last().time - history.first().time
            slider.progress = if (span <= 0) 1000 else (((selectedTime ?: history.last().time) - history.first().time) * 1000 / span).toInt()
            playbackLabel.text = (if (selectedTime == null) "完整軌跡" else "回放 ${format.format(Date(selectedTime!!))}") +
                " · ${format.format(Date(history.first().time))} — ${format.format(Date(history.last().time))}"
        } else playbackLabel.text = "尚無歷史資料"
        val googleMap = map ?: return
        clearMap()
        for (segment in HistoryGeometry.segments(visible)) {
            if (segment.size > 1) lines.add(googleMap.addPolyline(PolylineOptions()
                .addAll(segment.map { LatLng(it.latitude, it.longitude) }).color(blue).width(dp(4).toFloat())))
            else googleMap.addCircle(CircleOptions().center(LatLng(segment[0].latitude, segment[0].longitude))
                .radius(3.0).strokeColor(blue).fillColor(blue))?.let { /* Cleared with the map on redraw. */ }
        }
        visible.lastOrNull()?.let { last ->
            marker = googleMap.addMarker(MarkerOptions().position(LatLng(last.latitude, last.longitude))
                .title(if (selectedTime == null) "最後手機位置" else "回放手機位置")
                .snippet(format.format(Date(last.time))).icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE)))
        }
        cursorPoints = HistoryGeometry.segments(visible, maxPoints = 8000).flatten()
        val chosen = if (selectedTime != null) cursorPoints.lastOrNull()
            else cursorPoints.firstOrNull { it.id == cursorPoint?.id } ?: cursorPoints.firstOrNull()
        chosen?.let { point ->
            cursorPoint = point
            playbackLabel.text = "標定時間 ${cursorTime(point)} · 長按三角形可拖動"
            historyCursor = googleMap.addMarker(MarkerOptions()
                .position(LatLng(point.latitude, point.longitude)).icon(historyCursorIcon())
                .anchor(0.5f, 1f).draggable(true).zIndex(10f)
                .title(cursorTime(point)))
        }
        if (fitHistory && history.isNotEmpty()) {
            fitHistory = false
            mapView.post {
                if (!destroyed && mode == "history") {
                    if (history.size == 1) googleMap.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(history[0].latitude, history[0].longitude), 17f))
                    else {
                        val bounds = LatLngBounds.builder()
                        history.forEach { bounds.include(LatLng(it.latitude, it.longitude)) }
                        googleMap.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds.build(), dp(45)))
                    }
                }
            }
        }
    }
    private fun cursorTime(point: TrackPoint) = SimpleDateFormat("HH:mm:ss", Locale.TAIWAN).format(Date(point.time))
    private fun historyCursorIcon(): BitmapDescriptor {
        cursorIcon?.let { return it }
        val size = dp(32)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val triangle = Path().apply {
            moveTo(size * 0.12f, size * 0.15f); lineTo(size * 0.88f, size * 0.15f)
            lineTo(size * 0.5f, size * 0.95f); close()
        }
        val canvas = Canvas(bitmap)
        canvas.drawPath(triangle, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(234, 88, 12) })
        canvas.drawPath(triangle, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = dp(2).toFloat()
        })
        return BitmapDescriptorFactory.fromBitmap(bitmap).also { cursorIcon = it }
    }
    private fun snapHistoryCursor(dragged: Marker, finished: Boolean) {
        val projection = map?.projection ?: return
        val target = projection.toScreenLocation(dragged.position)
        val point = cursorPoints.minByOrNull {
            val screen = projection.toScreenLocation(LatLng(it.latitude, it.longitude))
            val dx = (screen.x - target.x).toDouble(); val dy = (screen.y - target.y).toDouble()
            dx * dx + dy * dy
        } ?: return
        cursorPoint = point
        dragged.title = cursorTime(point)
        playbackLabel.text = "標定時間 ${cursorTime(point)}"
        if (finished) {
            dragged.position = LatLng(point.latitude, point.longitude)
        }
    }
    private fun loadRecords() {
        val version = ++queryVersion
        val before = beforeId
        lastQueryAt = System.currentTimeMillis()
        worker.execute {
            try {
                val page = database.page(before)
                runOnUiThread {
                    if (destroyed || version != queryVersion || mode != "records") return@runOnUiThread
                    detailText.text = "共 ${page.total} 筆 · 每頁 50 筆 · 最多保留 ${String.format(Locale.TAIWAN, "%,d", LocationTrackerStore.MAX_RECORDS)} 筆"
                    records.removeAllViews()
                    val navigation = row()
                    navigation.addView(button("最新") { beforeId = 0; pageStack.clear(); loadRecords() }, weight())
                    navigation.addView(button("上一頁") {
                        if (pageStack.isNotEmpty()) { beforeId = pageStack.removeAt(pageStack.lastIndex); loadRecords() }
                    }.apply { isEnabled = pageStack.isNotEmpty() }, weight())
                    navigation.addView(button("更早") {
                        if (page.hasMore) { pageStack.add(beforeId); beforeId = page.points.last().id; loadRecords() }
                    }.apply { isEnabled = page.hasMore }, weight())
                    records.addView(navigation)
                    if (page.points.isEmpty()) records.addView(text("尚無位置記錄，請開始記錄並等待 GPS 定位。", 16))
                    page.points.forEach { point ->
                        records.addView(text("${format.format(Date(point.time))}\n" +
                            String.format(Locale.TAIWAN, "%.6f, %.6f · 精度 %.0f m", point.latitude, point.longitude, point.accuracy) +
                            "\n" + (point.speed?.let { String.format(Locale.TAIWAN, "%.1f km/h", it) } ?: "速度未知") +
                            " · " + when (point.motion) { "stationary" -> "靜止"; "moving" -> "移動"; else -> "狀態未知" }, 14)
                            .apply { setPadding(dp(8), dp(12), dp(8), dp(12)) })
                    }
                }
            } catch (_: Exception) { runOnUiThread { if (!destroyed && version == queryVersion) detailText.text = "位置記錄讀取失敗，請重新開啟分頁" } }
        }
    }
    private fun clearMap() { map?.clear(); marker = null; historyCursor = null; circle = null; lines.clear() }
    private fun text(value: String, size: Int) = TextView(this).apply { text = value; textSize = size.toFloat(); setTextColor(ink) }
    private fun button(value: String, action: () -> Unit) = Button(this).apply {
        text = value; textSize = 13f; isAllCaps = false; minHeight = dp(48)
        contentDescription = value
        setTextColor(blue)
        background = GradientDrawable().apply { setColor(Color.rgb(239, 246, 255)); cornerRadius = dp(12).toFloat() }
        setOnClickListener { action() }
    }
    private fun row() = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(8), dp(4), dp(8), dp(4)) }
    private fun weight() = LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(3), 0, dp(3), 0) }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    override fun onResume() {
        super.onResume(); mapView.onResume(); resumed = true
        ensureLocation(false)
        refreshRecordingNotification()
        handler.removeCallbacks(tick); handler.post(tick)
    }
    override fun onPause() {
        resumed = false; playing = false; animator?.cancel(); LocationTrackerService.displayLocation = null
        handler.removeCallbacks(tick); mapView.onPause(); super.onPause()
    }
    override fun onStart() { super.onStart(); mapView.onStart() }
    override fun onStop() { mapView.onStop(); super.onStop() }
    override fun onDestroy() {
        destroyed = true; queryVersion++; handler.removeCallbacks(tick); animator?.cancel()
        worker.shutdown(); mapExporter.close(); mapView.onDestroy(); super.onDestroy()
    }
    override fun onLowMemory() { super.onLowMemory(); mapView.onLowMemory() }
    override fun onSaveInstanceState(outState: Bundle) {
        mapExporter.saveState(outState)
        outState.putBoolean("waiting_notification", waitingForNotificationPermission)
        outState.putStringArrayList("navigation", navigationStack)
        outState.putString("mode", mode); outState.putLong("hours", hours)
        customStart?.let { outState.putLong("start", it) }; customEnd?.let { outState.putLong("end", it) }
        val mapState = Bundle(); mapView.onSaveInstanceState(mapState); outState.putBundle("map", mapState)
        super.onSaveInstanceState(outState)
    }
}
