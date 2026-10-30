package dev.alero.app

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Special access ("Acceso a notificaciones", granted by the user in system settings). It gives two things:
 * the phone's notifications (mirrored to the computer) and the active media sessions (shown and controlled
 * from the computer). Without the access both features are simply off.
 */
class NotifListener : NotificationListenerService() {
    private var controller: MediaController? = null
    private val sessions = MediaSessionManager.OnActiveSessionsChangedListener { pick(it) }
    private val media = object : MediaController.Callback() {
        override fun onMetadataChanged(m: MediaMetadata?) = pushMedia()
        override fun onPlaybackStateChanged(s: PlaybackState?) = pushMedia()
        override fun onSessionDestroyed() = pick(null)
    }
    private val main = Handler(Looper.getMainLooper())
    private val poll = object : Runnable {
        override fun run() {
            val all = getSystemService(MediaSessionManager::class.java)
                .getActiveSessions(ComponentName(this@NotifListener, NotifListener::class.java))
            pick(all)
            main.postDelayed(this, 2000)
        }
    }

    override fun onListenerConnected() {
        me = this
        Features.start(this) // the system can start this process on its own: the event loop must run then too
        val msm = getSystemService(MediaSessionManager::class.java)
        val cn = ComponentName(this, NotifListener::class.java)
        msm.addOnActiveSessionsChangedListener(sessions, cn)
        pick(msm.getActiveSessions(cn))
        main.removeCallbacks(poll)
        main.postDelayed(poll, 2000)
        Bridge.broadcast("pb.x.info", Features.info())
    }

    override fun onListenerDisconnected() {
        getSystemService(MediaSessionManager::class.java).removeOnActiveSessionsChangedListener(sessions)
        controller?.unregisterCallback(media)
        main.removeCallbacks(poll)
        controller = null
        me = null
        Bridge.broadcast("pb.x.media.state", JSONObject().put("active", false))
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        json(sbn)?.let { Bridge.broadcast("pb.x.notif.posted", it) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (worth(sbn)) Bridge.broadcast("pb.x.notif.removed", JSONObject().put("key", sbn.key))
    }

    private fun pick(list: List<MediaController>?) {
        val all = list ?: getSystemService(MediaSessionManager::class.java)
            .getActiveSessions(ComponentName(this, NotifListener::class.java))
        val players = all.filter {
            val metadata = it.metadata
            !metadata?.getString(MediaMetadata.METADATA_KEY_TITLE).isNullOrBlank() ||
                !metadata?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE).isNullOrBlank() ||
                (metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0) > 0
        }
        val next = players.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: players.firstOrNull { it.sessionToken == controller?.sessionToken } ?: players.firstOrNull()
        if (next?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(media)
            controller = next
            controller?.registerCallback(media, main)
        }
        pushMedia()
    }

    private fun pushMedia() {
        val s = state() ?: JSONObject().put("active", false)
        Bridge.broadcast("pb.x.media.state", s)
    }

    private fun state(): JSONObject? {
        val c = controller ?: return null
        val m = c.metadata
        val p = c.playbackState
        val am = getSystemService(AudioManager::class.java)
        val duration = m?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0
        val playing = p?.state == PlaybackState.STATE_PLAYING
        val elapsed = if (playing && p != null && p.lastPositionUpdateTime > 0)
            (SystemClock.elapsedRealtime() - p.lastPositionUpdateTime).coerceAtLeast(0) else 0
        val position = ((p?.position ?: 0) + elapsed * (p?.playbackSpeed ?: 1f)).toLong().coerceAtLeast(0)
        return JSONObject()
            .put("active", true)
            .put("app", appName(c.packageName))
            .put("title", m?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: m?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: "")
            .put("artist", m?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: m?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: "")
            .put("album", m?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: "")
            .put("duration", m?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0)
            .put("playing", p?.state == PlaybackState.STATE_PLAYING)
            .put("position", if (duration > 0) position.coerceAtMost(duration) else position)
            .put("speed", p?.playbackSpeed?.toDouble() ?: 1.0)
            .put("actions", p?.actions ?: 0)
            .put("at", System.currentTimeMillis())
            .put("volume", am.getStreamVolume(AudioManager.STREAM_MUSIC))
            .put("volumeMax", am.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
            .put("art", art(m))
    }

    /** Small JPEG of the cover (base64), so a frame stays well under the 64 KiB limit. */
    private fun art(m: MediaMetadata?): String {
        val b = m?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: m?.getBitmap(MediaMetadata.METADATA_KEY_ART) ?: return ""
        val side = 160
        val scale = minOf(1f, side.toFloat() / maxOf(1, b.width), side.toFloat() / maxOf(1, b.height))
        val small = Bitmap.createScaledBitmap(b, maxOf(1, (b.width * scale).toInt()), maxOf(1, (b.height * scale).toInt()), true)
        val out = ByteArrayOutputStream()
        small.compress(Bitmap.CompressFormat.JPEG, 70, out)
        if (small !== b) small.recycle()
        return if (out.size() > 40_000) "" else Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    private fun appName(pkg: String) = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    /** Ongoing, our own and group summaries are noise on the computer. */
    private fun worth(sbn: StatusBarNotification) =
        sbn.packageName != packageName && !sbn.isOngoing && sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0

    /** Launcher icon of the source app as a small PNG (base64); cached per package, "" when it has none. */
    private fun icon(pkg: String): String = icons.getOrPut(pkg) {
        try {
            val d = packageManager.getApplicationIcon(pkg)
            val b = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
            d.setBounds(0, 0, 64, 64)
            d.draw(android.graphics.Canvas(b))
            val out = ByteArrayOutputStream()
            b.compress(Bitmap.CompressFormat.PNG, 100, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        } catch (_: Exception) {
            ""
        }
    }

    private fun json(sbn: StatusBarNotification, withIcon: Boolean = true): JSONObject? {
        if (!worth(sbn)) return null
        val x = sbn.notification.extras
        val title = x.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (x.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: x.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return null
        return JSONObject()
            .put("key", sbn.key)
            .put("app", appName(sbn.packageName))
            .put("pkg", sbn.packageName)
            .put("icon", if (withIcon) icon(sbn.packageName) else "")
            .put("title", title.take(200))
            .put("text", text.take(1000))
            .put("time", sbn.postTime)
            .put("clearable", sbn.isClearable)
    }

    companion object {
        private var me: NotifListener? = null
        private val icons = HashMap<String, String>()

        fun enabled(c: Context): Boolean =
            Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners")?.contains(c.packageName) == true

        fun snapshot(): JSONObject? {
            val s = me ?: return null
            val items = JSONArray()
            // One icon per app: the snapshot would otherwise pass the frame limit.
            val sent = HashSet<String>()
            for (n in s.activeNotifications.orEmpty().sortedByDescending { it.postTime }.take(50))
                s.json(n, false)?.let { j -> // the icon goes on the first notification that is really sent
                    if (sent.add(n.packageName)) j.put("icon", s.icon(n.packageName))
                    items.put(j)
                }
            return JSONObject().put("items", items)
        }

        fun mediaState(): JSONObject? = me?.let { it.state() ?: JSONObject().put("active", false) }

        fun dismiss(key: String) {
            me?.cancelNotification(key)
        }

        /** `action`: toggle, play, pause, next, prev, seek (`position` ms) or volume (`value`). */
        fun command(b: JSONObject) {
            val s = me ?: return
            val t = s.controller?.transportControls
            when (b.optString("action")) {
                "toggle" -> if (s.controller?.playbackState?.state == PlaybackState.STATE_PLAYING) t?.pause() else t?.play()
                "play" -> t?.play()
                "pause" -> t?.pause()
                "next" -> t?.skipToNext()
                "prev" -> t?.skipToPrevious()
                "seek" -> t?.seekTo(b.optLong("position"))
                "volume" -> s.getSystemService(AudioManager::class.java)
                    .let { it.setStreamVolume(AudioManager.STREAM_MUSIC,
                        b.optInt("value").coerceIn(0, it.getStreamMaxVolume(AudioManager.STREAM_MUSIC)), 0) }
            }
            s.main.post { s.pushMedia() }
            s.main.postDelayed({ s.pushMedia() }, 350)
        }
    }
}
