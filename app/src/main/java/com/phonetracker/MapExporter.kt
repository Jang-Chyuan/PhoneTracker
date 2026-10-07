package com.phonetracker

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.widget.Toast
import androidx.core.content.FileProvider
import com.google.android.gms.maps.GoogleMap
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Export the map snapshot with its labels below the map, preserving map attribution. */
class MapExporter(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingFile: File? = null
    var busy = false; private set

    fun capture(map: GoogleMap, caption: String) {
        if (busy) return
        busy = true
        try {
            map.snapshot { bitmap ->
                if (activity.isFinishing || activity.isDestroyed) { bitmap?.recycle(); busy = false; return@snapshot }
                if (bitmap == null) { fail("地圖圖片尚未準備完成，請稍後重試"); return@snapshot }
                worker.execute {
                    try {
                        val padding = (bitmap.width / 40).coerceAtLeast(12)
                        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                            color = Color.rgb(30, 41, 59); textSize = (bitmap.width / 32f).coerceIn(14f, 32f)
                        }
                        val label = StaticLayout.Builder.obtain(caption, 0, caption.length, paint, bitmap.width - padding * 2)
                            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setIncludePad(false).build()
                        val output = Bitmap.createBitmap(bitmap.width, bitmap.height + label.height + padding * 2, Bitmap.Config.ARGB_8888)
                        try {
                            val canvas = Canvas(output)
                            canvas.drawColor(Color.WHITE)
                            canvas.drawBitmap(bitmap, 0f, 0f, null)
                            canvas.translate(padding.toFloat(), (bitmap.height + padding).toFloat())
                            label.draw(canvas)
                            val directory = File(activity.cacheDir, "map_exports").apply { check(isDirectory || mkdirs()) }
                            directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 7 * 86400000L }
                                ?.forEach { it.delete() }
                            val file = File(directory, "PhoneTracker-${UUID.randomUUID()}.png")
                            file.outputStream().use { check(output.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                            activity.runOnUiThread {
                                busy = false
                                if (!activity.isFinishing && !activity.isDestroyed) showOptions(file)
                            }
                        } finally { output.recycle(); bitmap.recycle() }
                    } catch (_: Exception) { fail("無法匯出地圖，請重試") }
                }
            }
        } catch (_: Exception) { fail("無法取得地圖圖片，請重試") }
    }

    private fun showOptions(file: File) {
        AlertDialog.Builder(activity).setTitle("匯出地圖圖片")
            .setItems(arrayOf("儲存圖片", "分享圖片")) { _, choice ->
                try {
                    if (choice == 0) {
                        pendingFile = file
                        @Suppress("DEPRECATION")
                        activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE).setType("image/png")
                            .putExtra(Intent.EXTRA_TITLE, file.name), SAVE_REQUEST)
                    } else {
                        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".mapexports", file)
                        val intent = Intent(Intent.ACTION_SEND).setType("image/png")
                            .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            .apply { clipData = ClipData.newRawUri("PhoneTracker 地圖", uri) }
                        activity.startActivity(Intent.createChooser(intent, "分享地圖圖片"))
                    }
                } catch (_: Exception) { pendingFile = null; fail("無法開啟匯出選單，請重試") }
            }.setNegativeButton("取消", null).show()
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_REQUEST) return
        val file = pendingFile
        pendingFile = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || file == null || uri == null) return
        busy = true
        worker.execute {
            try {
                val stream = activity.contentResolver.openOutputStream(uri, "wt") ?: error("無法開啟檔案")
                stream.use { out -> file.inputStream().use { it.copyTo(out) } }
                activity.runOnUiThread { busy = false; Toast.makeText(activity, "地圖圖片已儲存", Toast.LENGTH_SHORT).show() }
            } catch (_: Exception) { fail("儲存圖片失敗，請重試") }
        }
    }

    private fun fail(message: String) = activity.runOnUiThread {
        busy = false
        if (!activity.isFinishing && !activity.isDestroyed) Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
    }

    fun saveState(state: Bundle) { pendingFile?.let { state.putString("map_export_file", it.name) } }
    fun restoreState(state: Bundle?) {
        val name = state?.getString("map_export_file") ?: return
        if (name == File(name).name && name.startsWith("PhoneTracker-") && name.endsWith(".png"))
            pendingFile = File(activity.cacheDir, "map_exports/$name").takeIf { it.isFile }
    }
    fun close() { worker.shutdown() }
    companion object { private const val SAVE_REQUEST = 7315 }
}
