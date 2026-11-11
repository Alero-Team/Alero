package dev.alero.app

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
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
        replies.clear()
        Bridge.broadcast("pb.x.media.state", JSONObject().put("active", false))
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (Calls.isCall(sbn)) return Calls.posted(sbn)
        json(sbn)?.let { Bridge.broadcast("pb.x.notif.posted", it) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (Calls.isCall(sbn)) return Calls.removed(sbn)
        replies.remove(sbn.key)
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
            .put("pkg", c.packageName)
            .put("cast", c.playbackInfo?.playbackType == MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE)
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
        val b = m?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: m?.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: m?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            ?: return ""
        val side = 256
        val scale = minOf(1f, side.toFloat() / maxOf(1, b.width), side.toFloat() / maxOf(1, b.height))
        val small = Bitmap.createScaledBitmap(b, maxOf(1, (b.width * scale).toInt()), maxOf(1, (b.height * scale).toInt()), true)
        val out = ByteArrayOutputStream()
        var quality = 75
        do {
            out.reset()
            small.compress(Bitmap.CompressFormat.JPEG, quality, out)
            quality -= 10
        } while (out.size() > 40_000 && quality >= 35)
        if (small !== b) small.recycle()
        return if (out.size() > 40_000) "" else Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    private fun appName(pkg: String) = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    /** Ongoing, our own, group summaries and media players (shown in "Reproduciendo") are noise on the computer. */
    private fun worth(sbn: StatusBarNotification) =
        sbn.packageName != packageName && !sbn.isOngoing && !Calls.isCall(sbn) && sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 &&
            !sbn.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) &&
            sbn.packageName !in Prefs.muted(this)

    private fun icon(pkg: String): String = appIcon(this, pkg)

    /** The picture an app puts beside its notification (a chat's contact photo), as a small JPEG. "" if none. */
    private fun avatar(sbn: StatusBarNotification): String = try {
        val d = sbn.notification.getLargeIcon()?.loadDrawable(this)
        if (d == null) "" else {
            val b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
            val out = ByteArrayOutputStream()
            try {
                val c = android.graphics.Canvas(b)
                c.drawColor(android.graphics.Color.WHITE) // JPEG has no transparency
                d.setBounds(0, 0, 96, 96)
                d.draw(c)
                b.compress(Bitmap.CompressFormat.JPEG, 80, out)
            } finally { b.recycle() }
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }
    } catch (_: Exception) {
        ""
    }

    private fun json(sbn: StatusBarNotification, withIcon: Boolean = true): JSONObject? {
        if (!worth(sbn)) return null
        val x = sbn.notification.extras
        val title = x.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (x.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: x.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return null
        val action = sbn.notification.actions?.firstOrNull { a -> a.actionIntent != null && a.remoteInputs?.any { it.allowFreeFormInput } == true }
        if (action == null) replies.remove(sbn.key)
        else replies.put(sbn.key, ReplyTarget(action.actionIntent, action.remoteInputs), SystemClock.elapsedRealtime())
        return JSONObject()
            .put("key", sbn.key)
            .put("replyable", action != null)
            .put("app", appName(sbn.packageName))
            .put("pkg", sbn.packageName)
            .put("icon", if (withIcon) icon(sbn.packageName) else "")
            .put("avatar", avatar(sbn))
            .put("title", title.take(200))
            .put("text", text.take(1000))
            .put("time", sbn.postTime)
            .put("clearable", sbn.isClearable)
            .put("chat", chat(sbn))
            .put("conversation", (x.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) ?: title).toString().take(200))
            .put("messages", messages(sbn))
            .put("markable", semantic(sbn, Notification.Action.SEMANTIC_ACTION_MARK_AS_READ) != null)
            .put("mutable", semantic(sbn, Notification.Action.SEMANTIC_ACTION_MUTE) != null)
    }

    /** A conversation notification (WhatsApp, Telegram, Signal…): messaging style or the message category. */
    private fun chat(sbn: StatusBarNotification) =
        sbn.notification.category == Notification.CATEGORY_MESSAGE ||
            sbn.notification.extras.getString(Notification.EXTRA_TEMPLATE) == Notification.MessagingStyle::class.java.name

    /** The last messages a messaging-style notification carries (apps usually keep a few), oldest first. */
    @Suppress("DEPRECATION") // the typed getters need Android 13; these read every version
    private fun messages(sbn: StatusBarNotification): JSONArray {
        val a = JSONArray()
        val extras = sbn.notification.extras
        val raw = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return a
        // Apps like WhatsApp tag your own replies with your Person, not a null sender.
        val self = (if (android.os.Build.VERSION.SDK_INT >= 28)
            (extras.get(Notification.EXTRA_MESSAGING_PERSON) as? android.app.Person)?.name?.toString() else null)
            ?: extras.getCharSequence(Notification.EXTRA_SELF_DISPLAY_NAME)?.toString()
        for (p in raw.takeLast(10)) {
            val b = p as? Bundle ?: continue
            val text = b.getCharSequence("text")?.toString() ?: continue
            val sender = if (android.os.Build.VERSION.SDK_INT >= 28)
                (b.get("sender_person") as? android.app.Person)?.name?.toString() ?: b.getCharSequence("sender")?.toString()
            else b.getCharSequence("sender")?.toString()
            // No sender, or the conversation's own user, means the phone's owner wrote it.
            val out = sender == null || sender == self
            a.put(JSONObject().put("text", text.take(1000)).put("time", b.getLong("time")).put("sender", if (out) "" else sender).put("out", out))
        }
        return a
    }

    companion object {
        /** The app's own button for this meaning (Android 9+ messaging apps tag them), or null. */
        private fun semantic(sbn: StatusBarNotification, what: Int): Notification.Action? =
            if (android.os.Build.VERSION.SDK_INT < 28) null
            else sbn.notification.actions?.firstOrNull { it.semanticAction == what && it.actionIntent != null }

        /**
         * `read`: the app's "mark as read" button, else the notification is cleared (it is read on the computer).
         * `mute`: the app's "mute" button (that conversation). `muteApp`: this app's notifications stop reaching
         * computers until unmuted in Alero's settings on the phone.
         */
        fun act(body: JSONObject) {
            val s = me ?: return
            val sbn = try { s.activeNotifications.orEmpty().firstOrNull { it.key == body.optString("key") } } catch (_: Exception) { null } ?: return
            when (body.optString("action")) {
                "read" -> semantic(sbn, Notification.Action.SEMANTIC_ACTION_MARK_AS_READ)
                    ?.let { try { it.actionIntent.send() } catch (_: PendingIntent.CanceledException) {} }
                    ?: s.cancelNotification(sbn.key)
                "mute" -> semantic(sbn, Notification.Action.SEMANTIC_ACTION_MUTE)
                    ?.let { try { it.actionIntent.send() } catch (_: PendingIntent.CanceledException) {} }
                "muteApp" -> {
                    Prefs.setMuted(s, sbn.packageName, true)
                    // The computers drop what they show from that app.
                    s.activeNotifications.orEmpty().filter { it.packageName == sbn.packageName }
                        .forEach { Bridge.broadcast("pb.x.notif.removed", JSONObject().put("key", it.key)) }
                }
            }
        }

        fun mutedApps(c: Context): List<Map<String, String>> = Prefs.muted(c).map { pkg ->
            mapOf("pkg" to pkg, "name" to try { c.packageManager.getApplicationLabel(c.packageManager.getApplicationInfo(pkg, 0)).toString() } catch (_: Exception) { pkg })
        }.sortedBy { it["name"]!!.lowercase() }

        private var me: NotifListener? = null
        private data class ReplyTarget(val intent: PendingIntent, val inputs: Array<RemoteInput>)
        private val replies = ReplyTargets<ReplyTarget>()

        fun reply(body: JSONObject): JSONObject {
            val key = body.optString("key")
            val text = body.optString("text")
            val result = JSONObject().put("key", key).put("request", body.optString("request"))
            fun fail(reason: String) = result.put("ok", false).put("error", reason)
            // No length cap of our own: the message frame already bounds it, and the app decides what it accepts.
            replyTextError(text, key)?.let { return fail(it) }
            val service = me ?: return fail("no_access")
            val available = try { service.activeNotifications.orEmpty().any { it.key == key } }
                catch (_: Exception) { return fail("no_access") }
            if (!available) {
                replies.remove(key)
                return fail("expired")
            }
            val target = replies.get(key, SystemClock.elapsedRealtime()) ?: return fail("expired")
            return try {
                val results = Bundle()
                target.inputs.filter { it.allowFreeFormInput }.forEach { results.putCharSequence(it.resultKey, text) }
                val intent = Intent()
                RemoteInput.addResultsToIntent(target.inputs, intent, results)
                if (android.os.Build.VERSION.SDK_INT >= 28) RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
                target.intent.send(service, 0, intent)
                result.put("ok", true)
            } catch (e: PendingIntent.CanceledException) {
                // Binder refuses a too-large transaction this way too; that one is not an expired notification.
                if (e.cause is android.os.TransactionTooLargeException) return fail("too_large")
                replies.remove(key)
                fail("expired")
            } catch (_: android.os.TransactionTooLargeException) {
                fail("too_large")
            } catch (_: Exception) { fail("send_failed") }
        }

        /** Why a reply cannot be sent, or null. Only empty text and an absurd key are refused, never length. */
        fun replyTextError(text: String, key: String): String? =
            if (text.isBlank() || key.isEmpty() || key.length > 2048) "invalid_text" else null

        fun enabled(c: Context): Boolean =
            Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners")?.contains(c.packageName) == true

        fun snapshot(): JSONObject? {
            val s = me ?: return null
            val items = JSONArray()
            // One icon per app: the snapshot would otherwise pass the frame limit.
            val sent = HashSet<String>()
            var size = 0
            for (n in s.activeNotifications.orEmpty().sortedByDescending { it.postTime }.take(50))
                s.json(n, false)?.let { j -> // the icon goes on the first notification that is really sent
                    if (sent.add(n.packageName)) j.put("icon", s.icon(n.packageName))
                    // Chats carry their last messages: stay well under the 256 KiB frame, newest first.
                    size += j.toString().length
                    if (size > 200_000) return JSONObject().put("items", items)
                    items.put(j)
                }
            return JSONObject().put("items", items)
        }

        private val icons = java.util.concurrent.ConcurrentHashMap<String, String>()

        /** Launcher icon of an app as a small PNG (base64); cached per package, "" when it has none. */
        fun appIcon(c: Context, pkg: String): String = icons.getOrPut(pkg) {
            try {
                val d = c.packageManager.getApplicationIcon(pkg)
                val b = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
                d.setBounds(0, 0, 64, 64)
                d.draw(android.graphics.Canvas(b))
                val out = ByteArrayOutputStream()
                try { b.compress(Bitmap.CompressFormat.PNG, 100, out) } finally { b.recycle() }
                Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            } catch (_: Exception) {
                ""
            }
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
