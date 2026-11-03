package dev.alero.app

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.CallLog
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject

/**
 * Phone controls for a paired computer (`pb.x.phone.*`): Do Not Disturb, flashlight, ringer, volumes, "find my
 * phone", recent calls and a contact search for the dialer. Wi-Fi and Bluetooth need adb (Android lets no
 * ordinary app switch them), so the computer does those itself over USB / wireless debugging.
 */
object Phone {
    private lateinit var ctx: Context
    private val main = Handler(Looper.getMainLooper())
    private var torch = false
    private var player: MediaPlayer? = null
    private var alarmBefore = -1
    private const val FIND_NOTICE = 3
    private val autoStop = Runnable { stopFind() }

    fun init(c: Context) {
        ctx = c.applicationContext
        try {
            ctx.getSystemService(CameraManager::class.java).registerTorchCallback(object : CameraManager.TorchCallback() {
                override fun onTorchModeChanged(id: String, on: Boolean) {
                    torch = on
                    tell()
                }
            }, main)
        } catch (_: Exception) {}
    }

    private fun has(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    private fun audio() = ctx.getSystemService(AudioManager::class.java)
    private fun nm() = ctx.getSystemService(NotificationManager::class.java)

    fun state(): JSONObject {
        val a = audio()
        return JSONObject()
            .put("dnd", nm().currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL)
            .put("dndAccess", nm().isNotificationPolicyAccessGranted)
            .put("torch", torch)
            .put("finding", player != null)
            .put("ringer", when (a.ringerMode) { AudioManager.RINGER_MODE_SILENT -> "silent"; AudioManager.RINGER_MODE_VIBRATE -> "vibrate"; else -> "normal" })
            .put("media", a.getStreamVolume(AudioManager.STREAM_MUSIC)).put("mediaMax", a.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
            .put("ring", a.getStreamVolume(AudioManager.STREAM_RING)).put("ringMax", a.getStreamMaxVolume(AudioManager.STREAM_RING))
            .put("callLog", has(Manifest.permission.READ_CALL_LOG))
    }

    private fun tell() = Bridge.broadcast("pb.x.phone.state", state())

    fun handle(peer: String, kind: String, b: JSONObject) {
        main.post {
            val error = try {
                when (kind) {
                    "pb.x.phone.state.request" -> null
                    "pb.x.phone.dnd" -> dnd(b.optBoolean("on"))
                    "pb.x.phone.torch" -> { setTorch(b.optBoolean("on")); null }
                    "pb.x.phone.ringer" -> ringer(b.optString("mode"))
                    "pb.x.phone.volume" -> { volume(b.optString("stream"), b.optInt("value")); null }
                    "pb.x.phone.find" -> { if (b.optBoolean("on")) find() else stopFind(); null }
                    "pb.x.phone.calllog.request" -> { Thread { Bridge.sendTo(peer, "pb.x.phone.calllog", calls()) }.start(); return@post }
                    "pb.x.phone.icons" -> { val pkgs = b.optJSONArray("pkgs") ?: JSONArray(); Thread { icons(peer, pkgs) }.start(); return@post }
                    "pb.x.phone.contacts" -> { val q = b.optString("q"); Thread { Bridge.sendTo(peer, "pb.x.phone.contacts.result", contacts(q)) }.start(); return@post }
                    else -> "unknown"
                }
            } catch (_: SecurityException) { "no_permission" } catch (_: Exception) { "failed" }
            if (error != null) Bridge.sendTo(peer, "pb.x.phone.error", JSONObject().put("kind", kind).put("error", error))
            Bridge.sendTo(peer, "pb.x.phone.state", state())
        }
    }

    /** Needs Android's "Do Not Disturb access" for Alero; without it the owner gets a notice that opens that screen. */
    private fun dnd(on: Boolean): String? {
        if (!nm().isNotificationPolicyAccessGranted) {
            askDndAccess()
            return "dnd_access"
        }
        nm().setInterruptionFilter(if (on) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL)
        return null
    }

    private fun askDndAccess() {
        val i = PendingIntent.getActivity(ctx, 7, Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(ctx, "alerts").setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle("No molestar desde el ordenador")
            .setContentText("Toca y permite a Alero el acceso a «No molestar».")
            .setContentIntent(i).setAutoCancel(true).build()
        try { nm().notify(8, n) } catch (_: SecurityException) {}
    }

    private fun setTorch(on: Boolean) {
        val cm = ctx.getSystemService(CameraManager::class.java)
        val id = cm.cameraIdList.firstOrNull { cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true } ?: return
        cm.setTorchMode(id, on)
        torch = on
    }

    /** Silent needs Do Not Disturb access since Android 7; vibrate and normal do not. */
    private fun ringer(mode: String): String? {
        val m = when (mode) { "silent" -> AudioManager.RINGER_MODE_SILENT; "vibrate" -> AudioManager.RINGER_MODE_VIBRATE; else -> AudioManager.RINGER_MODE_NORMAL }
        if (m == AudioManager.RINGER_MODE_SILENT && !nm().isNotificationPolicyAccessGranted) {
            askDndAccess()
            return "dnd_access"
        }
        audio().ringerMode = m
        return null
    }

    private fun volume(stream: String, value: Int) {
        val s = if (stream == "ring") AudioManager.STREAM_RING else AudioManager.STREAM_MUSIC
        audio().setStreamVolume(s, value.coerceIn(0, audio().getStreamMaxVolume(s)), 0)
    }

    // --- find my phone ----------------------------------------------------------------------------------

    /** Rings at full alarm volume (alarms pass Do Not Disturb) and vibrates for a minute, or until stopped. */
    private fun find() {
        if (player != null) return
        val a = audio()
        alarmBefore = a.getStreamVolume(AudioManager.STREAM_ALARM)
        a.setStreamVolume(AudioManager.STREAM_ALARM, a.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        val uri: Uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        player = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            setDataSource(ctx, uri)
            isLooping = true
            prepare()
            start()
        }
        ctx.getSystemService(Vibrator::class.java)?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 800, 400), 0))
        val stop = PendingIntent.getBroadcast(ctx, 9, Intent(ctx, StopFind::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(ctx, "alerts").setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle("¡Aquí estoy!").setContentText("Tu ordenador está buscando este teléfono.")
            .setOngoing(true).setContentIntent(stop).setDeleteIntent(stop)
            .addAction(Notification.Action.Builder(null, "Detener", stop).build()).build()
        try { nm().notify(FIND_NOTICE, n) } catch (_: SecurityException) {}
        main.postDelayed(autoStop, 60_000)
        tell()
    }

    fun stopFind() {
        val p = player ?: return
        player = null
        main.removeCallbacks(autoStop)
        try { p.stop() } catch (_: Exception) {}
        p.release()
        ctx.getSystemService(Vibrator::class.java)?.cancel()
        if (alarmBefore >= 0) audio().setStreamVolume(AudioManager.STREAM_ALARM, alarmBefore, 0)
        nm().cancel(FIND_NOTICE)
        tell()
    }

    /** App icons for the computer's app grid, a few per message to stay under the frame limit. */
    private fun icons(peer: String, pkgs: JSONArray) {
        var batch = JSONObject()
        for (i in 0 until minOf(pkgs.length(), 400)) {
            val pkg = pkgs.optString(i)
            val png = NotifListener.appIcon(ctx, pkg)
            if (png.isNotEmpty()) batch.put(pkg, png)
            if (batch.length() >= 8) {
                Bridge.sendTo(peer, "pb.x.phone.icons.result", JSONObject().put("icons", batch))
                batch = JSONObject()
            }
        }
        if (batch.length() > 0) Bridge.sendTo(peer, "pb.x.phone.icons.result", JSONObject().put("icons", batch))
    }

    // --- calls and contacts -----------------------------------------------------------------------------

    private fun calls(): JSONObject {
        if (!has(Manifest.permission.READ_CALL_LOG)) return JSONObject().put("error", "no_permission").put("items", JSONArray())
        val a = JSONArray()
        ctx.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            null, null, "${CallLog.Calls.DATE} DESC",
        )?.use { c ->
            while (c.moveToNext() && a.length() < 80) {
                a.put(JSONObject().put("number", c.getString(0) ?: "").put("name", c.getString(1) ?: "")
                    .put("type", when (c.getInt(2)) {
                        CallLog.Calls.INCOMING_TYPE -> "in"; CallLog.Calls.OUTGOING_TYPE -> "out"
                        CallLog.Calls.MISSED_TYPE -> "missed"; CallLog.Calls.REJECTED_TYPE -> "rejected"; else -> "other"
                    })
                    .put("date", c.getLong(3)).put("duration", c.getLong(4)))
            }
        }
        return JSONObject().put("items", a)
    }

    private fun contacts(q: String): JSONObject {
        if (!has(Manifest.permission.READ_CONTACTS)) return JSONObject().put("error", "no_permission").put("items", JSONArray())
        val a = JSONArray()
        val uri = if (q.isBlank()) ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            else Uri.withAppendedPath(ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI, Uri.encode(q.trim().take(64)))
        val seen = HashSet<String>()
        ctx.contentResolver.query(
            uri, arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
            null, null, "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { c ->
            while (c.moveToNext() && a.length() < 60) {
                val n = c.getString(1) ?: continue
                if (seen.add(n.filter { it.isDigit() || it == '+' })) a.put(JSONObject().put("name", c.getString(0) ?: n).put("number", n))
            }
        }
        return JSONObject().put("q", q).put("items", a)
    }
}

/** "Detener" (or a tap) on the find-my-phone notice. */
class StopFind : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) = Phone.stopFind()
}
