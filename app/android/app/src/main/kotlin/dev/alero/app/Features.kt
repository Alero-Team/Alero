package dev.alero.app

import android.app.WallpaperManager
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.view.RoundedCorner
import android.view.WindowManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Phone side of the app messages (Protocol.md §6, `pb.x.*`). Runs in the foreground service, so it keeps
 * working without the UI. Each handler only uses public Android APIs; the special ones (notification access)
 * are granted by the user in system settings.
 */
object Features {
    private lateinit var ctx: Context
    private val main = Handler(Looper.getMainLooper())
    private var lastBattery = -1 to false
    private val online = LinkedHashMap<String, String>() // paired computers connected now: id -> name

    fun onlineNames(): List<String> = synchronized(online) { online.values.toList() }

    fun start(c: Context) {
        if (::ctx.isInitialized) return
        ctx = c.applicationContext
        Files.init(ctx)
        Thread(::loop, "pb-features").apply { isDaemon = true }.start()
        ctx.registerReceiver(object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val now = battery()
                // Only real changes: every 1 % or a plug/unplug.
                if (now.first != lastBattery.first || now.second != lastBattery.second) {
                    lastBattery = now
                    Bridge.broadcast("pb.x.info", info())
                }
            }
        }, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    }

    private fun loop() {
        while (true) {
            val line = try { Bridge.next(5000) } catch (_: Throwable) { null } ?: continue
            try {
                handle(JSONObject(line))
            } catch (_: Exception) {
                // a malformed message from a paired device must not stop the loop
            }
        }
    }

    private fun handle(e: JSONObject) {
        when (e.optString("type")) {
            "PeerChanged" -> {
                val p = e.getJSONObject("peer")
                if (!p.optBoolean("trusted")) return
                val id = p.getString("id")
                val fresh = synchronized(online) {
                    if (p.optString("state") == "Connected") online.put(id, p.optString("name")) == null else { online.remove(id); false }
                }
                if (fresh) hello(id)
                // The foreground service (and its notification) exists only while a computer is connected.
                PbService.update(ctx, onlineNames())
            }
            "TransferFinished" -> Files.finished(e.getString("id"))
            "Message" -> {
                val peer = e.getString("peer_id")
                val body = e.optJSONObject("body") ?: JSONObject()
                val kind = e.getString("kind")
                if (kind.startsWith("pb.x.fs.")) return Files.handle(peer, kind, body)
                when (kind) {
                    "pb.x.info.request" -> hello(peer)
                    "pb.x.clip" -> setClipboard(body.optString("text"))
                    "pb.x.media.cmd" -> NotifListener.command(body)
                    "pb.x.notif.dismiss" -> NotifListener.dismiss(body.optString("key"))
                }
            }
        }
    }

    /** Everything a newly connected computer needs to draw this phone. */
    private fun hello(peer: String) {
        Bridge.sendTo(peer, "pb.x.info", info())
        wallpaperMessage()?.let { Bridge.sendTo(peer, "pb.x.wallpaper", it) }
        NotifListener.snapshot()?.let { Bridge.sendTo(peer, "pb.x.notif.snapshot", it) }
        NotifListener.mediaState()?.let { Bridge.sendTo(peer, "pb.x.media.state", it) }
    }

    private fun battery(): Pair<Int, Boolean> {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return -1 to false
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
        return (if (level < 0) -1 else level * 100 / scale) to plugged
    }

    private fun network(): String {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val c = cm.getNetworkCapabilities(cm.activeNetwork) ?: return ""
        return when {
            c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> ""
        }
    }

    /** Screen geometry in pixels, so the computer can draw a faithful outline of this phone. */
    private fun screen(): JSONObject {
        val wm = ctx.getSystemService(WindowManager::class.java)
        val o = JSONObject()
        if (Build.VERSION.SDK_INT >= 30) {
            val m = wm.maximumWindowMetrics
            val b = m.bounds
            // Portrait numbers whatever the current rotation.
            o.put("w", minOf(b.width(), b.height())).put("h", maxOf(b.width(), b.height()))
            val ins = m.windowInsets
            if (Build.VERSION.SDK_INT >= 31) {
                ins.getRoundedCorner(RoundedCorner.POSITION_TOP_LEFT)?.let { o.put("radius", it.radius) }
            }
            ins.displayCutout?.boundingRects?.firstOrNull()?.let {
                o.put("cutout", JSONObject().put("x", it.left).put("y", it.top).put("w", it.width()).put("h", it.height()))
            }
        }
        o.put("density", ctx.resources.displayMetrics.density.toDouble())
        return o
    }

    fun info(): JSONObject {
        val (level, charging) = battery()
        val fs = StatFs(ctx.filesDir.path)
        return JSONObject()
            .put("kind", "phone")
            .put("manufacturer", Build.MANUFACTURER ?: "")
            .put("model", Build.MODEL ?: "")
            .put("os", "Android")
            .put("osVersion", Build.VERSION.RELEASE ?: "")
            .put("battery", JSONObject().put("level", level).put("charging", charging))
            .put("storage", JSONObject().put("free", fs.availableBytes).put("total", fs.totalBytes))
            .put("network", network())
            .put("screen", screen())
            .put("wallpaper", JSONObject().put("colors", wallpaperColors()).put("custom", wallpaperFile().exists()))
            .put("notifAccess", NotifListener.enabled(ctx))
    }

    /**
     * The user's wallpaper, as far as Android lets an ordinary app know it: its dominant colours (no permission
     * needed). The image itself is not readable without a broad storage permission, so the user may pick one.
     */
    private fun wallpaperColors(): JSONArray {
        val a = JSONArray()
        if (Build.VERSION.SDK_INT < 27) return a
        val c = ctx.getSystemService(WallpaperManager::class.java).getWallpaperColors(WallpaperManager.FLAG_SYSTEM) ?: return a
        listOfNotNull(c.primaryColor, c.secondaryColor, c.tertiaryColor).forEach { a.put(it.toArgb()) }
        return a
    }

    private fun wallpaperFile() = File(ctx.filesDir, "wallpaper.jpg")

    /** Small JPEG that fits in one app message (64 KiB after base64). */
    private fun wallpaperMessage(): JSONObject? {
        val f = wallpaperFile()
        if (!f.exists()) return null
        return JSONObject().put("jpeg", Base64.encodeToString(f.readBytes(), Base64.NO_WRAP))
    }

    /** Scales the picked image down to a thumbnail the computer can draw inside its phone outline. */
    fun setWallpaper(uri: Uri?): Boolean {
        if (uri == null) {
            wallpaperFile().delete()
            Bridge.broadcast("pb.x.wallpaper", JSONObject().put("jpeg", ""))
            return true
        }
        val cr = ctx.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0) return false
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 540) sample *= 2
        val raw = cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) } ?: return false
        val k = minOf(270f / raw.width, 640f / raw.height)
        val bmp = Bitmap.createScaledBitmap(raw, maxOf(1, (raw.width * k).toInt()), maxOf(1, (raw.height * k).toInt()), true)
        var q = 75
        var out: ByteArray
        do {
            out = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, q, it) }.toByteArray()
            q -= 10
        } while (out.size > 44_000 && q > 15)
        if (out.size > 44_000) return false
        wallpaperFile().writeBytes(out)
        wallpaperMessage()?.let { Bridge.broadcast("pb.x.wallpaper", it) }
        Bridge.broadcast("pb.x.info", info())
        return true
    }

    /** Writing the clipboard is allowed in the background (only reading is restricted since Android 10). */
    private fun setClipboard(text: String) {
        if (text.isEmpty() || text.length > 60_000) return
        main.post {
            ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Alero", text))
        }
    }
}
