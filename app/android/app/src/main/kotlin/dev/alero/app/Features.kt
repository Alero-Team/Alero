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
    private var lastMw = 0
    private var powerAt = 0L
    private val marketName by lazy { prop("ro.product.marketname").ifEmpty { prop("ro.product.vendor.marketname") } }
    private val replyResults = ReplyTargets<JSONObject>(100, 60_000)
    private val online = LinkedHashMap<String, String>() // paired computers connected now: id -> name

    fun onlineNames(): List<String> = synchronized(online) { online.values.toList() }

    fun start(c: Context) {
        if (::ctx.isInitialized) return
        ctx = c.applicationContext
        Files.init(ctx)
        Sms.init(ctx)
        Calls.init(ctx)
        Phone.init(ctx)
        WidgetData.init(ctx)
        TransferNotices.init(ctx)
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
        marketName // spawns getprop once, here and not on the main thread
        while (true) {
            val line = try { Bridge.next(5000) } catch (_: Throwable) { null }
            try { powerTick() } catch (_: Exception) { /* a missing reading must not stop the loop */ }
            try { WidgetData.tick() } catch (_: Throwable) {}
            if (line == null) continue
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
                val id = p.getString("id")
                val trusted = p.optBoolean("trusted")
                val connected = trusted && p.optString("state") == "Connected"
                if (trusted) WidgetData.peer(id, p.optString("name"), connected) else WidgetData.forget(id)
                val fresh = synchronized(online) {
                    if (connected) online.put(id, p.optString("name")) == null else { online.remove(id); false }
                }
                if (fresh) hello(id)
                if (!connected) Notifier.controlled(id, "", false) // the computer is gone: so is its session
                // Unpaired, rejected or disconnected on purpose: stop now instead of waiting for it to come back.
                val deliberate = !trusted || p.optString("state") == "Rejected" || p.optString("detail").startsWith("paused")
                // The foreground service (and its notification) exists only while a computer is connected.
                PbService.update(ctx, onlineNames(), linger = !deliberate)
            }
            "TransferOffer" -> TransferNotices.offer(e)
            "TransferStarted" -> {
                WidgetData.transferStarted(e)
                TransferNotices.started(e)
            }
            "TransferProgress" -> {
                WidgetData.transferProgress(e)
                TransferNotices.progress(e.getString("id"), e.optLong("done"), e.optLong("total"))
            }
            "TransferFinished" -> {
                WidgetData.transferFinished(e)
                TransferNotices.finished(e)
                Files.finished(e.getString("id"))
            }
            "Message" -> {
                val peer = e.getString("peer_id")
                val body = e.optJSONObject("body") ?: JSONObject()
                val kind = e.getString("kind")
                if (kind.startsWith("pb.x.fs.")) return Files.handle(peer, kind, body)
                if (kind.startsWith("pb.x.sms.")) return Sms.handle(peer, kind, body)
                if (kind == "pb.x.call.cmd" || kind == "pb.x.call.dial") return Calls.handle(peer, kind, body)
                if (kind.startsWith("pb.x.phone.")) return Phone.handle(peer, kind, body)
                when (kind) {
                    "pb.x.info.request" -> hello(peer)
                    "pb.x.info" -> WidgetData.info(peer, body)
                    "pb.x.pcmedia.state" -> WidgetData.media(body)
                    "pb.x.phonecontrol" -> Notifier.controlled(peer, synchronized(online) { online[peer] } ?: "Un ordenador", body.optBoolean("active"))
                    "pb.x.clip" -> setClipboard(body.optString("text"))
                    "pb.x.media.cmd" -> main.post { NotifListener.command(body) }
                    "pb.x.media.request" -> NotifListener.mediaState()?.let { Bridge.sendTo(peer, "pb.x.media.state", it) }
                    "pb.x.notif.dismiss" -> NotifListener.dismiss(body.optString("key"))
                    "pb.x.notif.action" -> main.post { NotifListener.act(body) }
                    "pb.x.notif.reply" -> main.post {
                        val request = body.optString("request").take(200)
                        val key = "$peer|$request"
                        val now = android.os.SystemClock.elapsedRealtime()
                        val result = (if (request.isEmpty()) null else replyResults.get(key, now)) ?: NotifListener.reply(body).also {
                            if (request.isNotEmpty()) replyResults.put(key, it, now)
                        }
                        Bridge.sendTo(peer, "pb.x.notif.reply.result", result)
                    }
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
        Calls.snapshot()?.let { Bridge.sendTo(peer, "pb.x.call", it) }
        Bridge.sendTo(peer, "pb.x.phone.state", Phone.state())
    }

    fun phoneBattery(): Pair<Int, Boolean> = if (::ctx.isInitialized) battery() else -1 to false

    private fun battery(): Pair<Int, Boolean> {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return -1 to false
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
        return (if (level < 0) -1 else level * 100 / scale) to plugged
    }

    /** Milliwatts going into the battery now (see [ChargePower]); 0 when not charging. */
    private fun power(): Int {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return 0
        val charging = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1) == BatteryManager.BATTERY_STATUS_CHARGING
        val raw = ctx.getSystemService(BatteryManager::class.java).getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        return ChargePower.milliwatts(raw, i.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0), charging)
    }

    private fun millivolts(): Int =
        ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0) ?: 0

    /** Charging power moves without the level changing, so it has its own small message: every 5 s, real changes only. */
    private fun powerTick() {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - powerAt < 5000 || onlineNames().isEmpty()) return
        powerAt = now
        val mw = power()
        if (Math.abs(mw - lastMw) >= 300 || (mw == 0) != (lastMw == 0)) {
            lastMw = mw
            Bridge.broadcast("pb.x.power", JSONObject().put("mw", mw).put("mv", millivolts()))
        }
    }

    /** A system property any app may read (`getprop`); empty if the device does not define it. */
    private fun prop(name: String): String = try {
        Runtime.getRuntime().exec(arrayOf("getprop", name)).inputStream.bufferedReader().use { it.readText().trim() }
    } catch (_: Exception) { "" }

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
        if (!o.has("w")) {
            val metrics = android.util.DisplayMetrics()
            @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(metrics)
            o.put("w", minOf(metrics.widthPixels, metrics.heightPixels)).put("h", maxOf(metrics.widthPixels, metrics.heightPixels))
        }
        if (Build.MODEL.equals("Pixel 9a", true)) {
            o.put("bodyWidthMm", 73.3).put("bodyHeightMm", 154.7).put("depthMm", 8.9)
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
            .put("brand", Build.BRAND ?: "")
            .put("device", Build.DEVICE ?: "")
            .put("product", Build.PRODUCT ?: "")
            .put("marketName", marketName)
            .put("os", "Android")
            .put("osVersion", Build.VERSION.RELEASE ?: "")
            .put("battery", JSONObject().put("level", level).put("charging", charging).put("mw", power()).put("mv", millivolts()))
            .put("storage", JSONObject().put("free", fs.availableBytes).put("total", fs.totalBytes))
            .put("network", network())
            .put("screen", screen())
            .put("wallpaper", JSONObject().put("colors", wallpaperColors()).put("custom", wallpaperFile().exists()))
            .put("notifAccess", NotifListener.enabled(ctx))
            .put("sms", Sms.allowed())
            .put("calls", Calls.allowed())
    }

    /** Tells every connected computer what changed (a switch or a permission in Settings). */
    fun announce() = Bridge.broadcast("pb.x.info", info())

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
        val f = File(ctx.cacheDir, "stock-wallpaper.jpg")
        if (!f.exists()) {
            try {
                val drawable = ctx.getSystemService(WallpaperManager::class.java).getBuiltInDrawable() ?: return null
                val width = 320
                val height = (width.toFloat() * drawable.intrinsicHeight / maxOf(1, drawable.intrinsicWidth)).toInt().coerceIn(1, 960)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                drawable.setBounds(0, 0, width, height)
                drawable.draw(android.graphics.Canvas(bitmap))
                f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 78, it) }
                bitmap.recycle()
            } catch (_: Exception) { return null }
        }
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
