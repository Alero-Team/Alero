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
    private var lastMedia = ""

    override fun onListenerConnected() {
        me = this
        Features.start(this) // the system can start this process on its own: the event loop must run then too
        val msm = getSystemService(MediaSessionManager::class.java)
        val cn = ComponentName(this, NotifListener::class.java)
        msm.addOnActiveSessionsChangedListener(sessions, cn)
        pick(msm.getActiveSessions(cn))
        Bridge.broadcast("pb.x.info", Features.info())
    }

    override fun onListenerDisconnected() {
        getSystemService(MediaSessionManager::class.java).removeOnActiveSessionsChangedListener(sessions)
        controller?.unregisterCallback(media)
        me = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        json(sbn)?.let { Bridge.broadcast("pb.x.notif.posted", it) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (worth(sbn)) Bridge.broadcast("pb.x.notif.removed", JSONObject().put("key", sbn.key))
    }

    private fun pick(list: List<MediaController>?) {
        controller?.unregisterCallback(media)
        // The one that is playing, else the most recent.
        controller = list?.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list?.firstOrNull()
        controller?.registerCallback(media)
        pushMedia()
    }

    private fun pushMedia() {
        val s = state() ?: JSONObject().put("active", false)
        // Same track and state: skip (callbacks fire often); position is extrapolated on the computer.
        val sig = s.optString("title") + s.optBoolean("playing") + s.optString("app") + s.optLong("duration")
        if (sig == lastMedia) return
        lastMedia = sig
        Bridge.broadcast("pb.x.media.state", s)
    }

    private fun state(): JSONObject? {
        val c = controller ?: return null
        val m = c.metadata
        val p = c.playbackState
        val am = getSystemService(AudioManager::class.java)
        return JSONObject()
            .put("active", true)
            .put("app", appName(c.packageName))
            .put("title", m?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: "")
            .put("artist", m?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: m?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: "")
            .put("album", m?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: "")
            .put("duration", m?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0)
            .put("playing", p?.state == PlaybackState.STATE_PLAYING)
            .put("position", p?.position ?: 0)
            .put("at", System.currentTimeMillis())
            .put("volume", am.getStreamVolume(AudioManager.STREAM_MUSIC))
            .put("volumeMax", am.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
            .put("art", art(m))
    }

    /** Small JPEG of the cover (base64), so a frame stays well under the 64 KiB limit. */
    private fun art(m: MediaMetadata?): String {
        val b = m?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: m?.getBitmap(MediaMetadata.METADATA_KEY_ART) ?: return ""
        val side = 160
        val small = Bitmap.createScaledBitmap(b, side, side * b.height / maxOf(1, b.width), true)
        val out = ByteArrayOutputStream()
        small.compress(Bitmap.CompressFormat.JPEG, 70, out)
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

    private fun json(sbn: StatusBarNotification): JSONObject? {
        if (!worth(sbn)) return null
        val x = sbn.notification.extras
        val title = x.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (x.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: x.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return null
        return JSONObject()
            .put("key", sbn.key)
            .put("app", appName(sbn.packageName))
            .put("title", title.take(200))
            .put("text", text.take(1000))
            .put("time", sbn.postTime)
            .put("clearable", sbn.isClearable)
    }

    companion object {
        private var me: NotifListener? = null

        fun enabled(c: Context): Boolean =
            Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners")?.contains(c.packageName) == true

        fun snapshot(): JSONObject? {
            val s = me ?: return null
            val items = JSONArray()
            for (n in s.activeNotifications.orEmpty().sortedByDescending { it.postTime }.take(50)) s.json(n)?.let { items.put(it) }
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
                    .setStreamVolume(AudioManager.STREAM_MUSIC, b.optInt("value"), 0)
            }
            s.lastMedia = "" // the reply may not change the signature (e.g. volume); force one update
            s.pushMedia()
        }
    }
}
