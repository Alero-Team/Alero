package dev.alero.app

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import org.json.JSONObject

/**
 * Phone calls on a paired computer (`pb.x.call*`). The dialer's call notification says who is calling and,
 * on Android 12+ (CallStyle), carries its own answer / decline / hang-up buttons, used only when TelecomManager
 * cannot (see `command`). Calls are placed with TelecomManager too, so no screen has to open on the phone.
 * The call's audio stays on the phone (or its headset). Off until the owner turns it on in Settings.
 */
object Calls {
    private lateinit var ctx: Context
    private var current: StatusBarNotification? = null

    val permissions = arrayOf(Manifest.permission.ANSWER_PHONE_CALLS, Manifest.permission.CALL_PHONE, Manifest.permission.READ_CALL_LOG)

    fun init(c: Context) {
        ctx = c.applicationContext
    }

    private fun has(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    fun granted() = has(Manifest.permission.ANSWER_PHONE_CALLS) && has(Manifest.permission.CALL_PHONE)
    fun allowed() = ::ctx.isInitialized && Prefs.calls(ctx) && granted()

    fun isCall(sbn: StatusBarNotification) = sbn.notification.category == Notification.CATEGORY_CALL

    private fun intent(sbn: StatusBarNotification?, key: String): PendingIntent? =
        if (Build.VERSION.SDK_INT < 31 || sbn == null) null
        else @Suppress("DEPRECATION") (sbn.notification.extras.getParcelable(key) as? PendingIntent)

    /** What the computer shows: who, and whether it is ringing or already talking. */
    private fun state(sbn: StatusBarNotification): JSONObject {
        val x = sbn.notification.extras
        val type = if (Build.VERSION.SDK_INT >= 31) x.getInt(Notification.EXTRA_CALL_TYPE, 0) else 0
        val telecom = ctx.getSystemService(TelecomManager::class.java)
        // CallStyle says it; older dialers: an answer button means it is still ringing.
        val ringing = when (type) {
            Notification.CallStyle.CALL_TYPE_INCOMING, Notification.CallStyle.CALL_TYPE_SCREENING -> true
            Notification.CallStyle.CALL_TYPE_ONGOING -> false
            else -> intent(sbn, Notification.EXTRA_ANSWER_INTENT) != null ||
                (sbn.notification.actions?.size ?: 0) >= 2 && sbn.notification.fullScreenIntent != null
        }
        return JSONObject()
            .put("active", true)
            .put("ringing", ringing)
            .put("name", (x.getCharSequence(Notification.EXTRA_TITLE) ?: "").toString().take(200))
            .put("text", (x.getCharSequence(Notification.EXTRA_TEXT) ?: "").toString().take(200))
            .put("canAnswer", ringing && (intent(sbn, Notification.EXTRA_ANSWER_INTENT) != null || has(Manifest.permission.ANSWER_PHONE_CALLS)))
            .put("inCall", try { telecom.isInCall } catch (_: SecurityException) { true })
            .put("muted", audio().isMicrophoneMute)
    }

    // The microphone mute is AudioManager's: a non-dialer app has nothing else (the loudspeaker route stays the
    // dialer's on Android 12+; tried on a Pixel 9a, Android 17, it was refused half the time).
    private fun audio() = ctx.getSystemService(AudioManager::class.java)

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    // Signal (and other apps) swap their call notification for a new one as the call changes: removed, then posted.
    // Said at once, the computer would end the call and start another, its timer back at 0:00.
    private val ended = Runnable { if (current == null && allowed()) Bridge.broadcast("pb.x.call", JSONObject().put("active", false)) }

    fun posted(sbn: StatusBarNotification) {
        if (!allowed()) return
        main.removeCallbacks(ended)
        current = sbn
        Bridge.broadcast("pb.x.call", state(sbn))
    }

    fun removed(sbn: StatusBarNotification) {
        if (current?.key != sbn.key) return
        current = null
        main.postDelayed(ended, 1500)
    }

    /** Sent when a computer connects, so a call already in progress shows up. */
    fun snapshot(): JSONObject? = if (!allowed()) null else current?.let { state(it) } ?: JSONObject().put("active", false)

    fun handle(peer: String, kind: String, body: JSONObject) {
        if (!allowed()) {
            Bridge.sendTo(peer, "pb.x.call.result", JSONObject().put("ok", false).put("error", if (Prefs.calls(ctx)) "no_permission" else "not_allowed"))
            return
        }
        val error = try {
            when (kind) {
                "pb.x.call.cmd" -> command(body.optString("action"))
                "pb.x.call.dial" -> dial(body.optString("number"))
                else -> null
            }
        } catch (_: SecurityException) { "no_permission" } catch (_: Exception) { "failed" }
        Bridge.sendTo(peer, "pb.x.call.result", JSONObject().put("ok", error == null).put("error", error ?: "").put("kind", kind))
    }

    /**
     * TelecomManager first: it answers or ends the ringing call itself (the SIM's, or a VoIP app's that uses Telecom,
     * like Signal). The notification's own buttons are only the fallback without ANSWER_PHONE_CALLS: Google's dialer
     * answers through an activity, which Android 14+ blocks when started from the background, so the call kept
     * ringing (and the dialer left its "incoming" notification behind). Seen on a Pixel 9a, Android 17.
     */
    @Suppress("DEPRECATION") // still the only public way for a non-dialer app
    private fun command(action: String): String? {
        val telecom = ctx.getSystemService(TelecomManager::class.java)
        val sbn = current
        val canTelecom = has(Manifest.permission.ANSWER_PHONE_CALLS)
        fun send(key: String) = intent(sbn, key)?.let { try { it.send(); true } catch (_: PendingIntent.CanceledException) { false } } == true
        fun end(key: String) = (canTelecom && Build.VERSION.SDK_INT >= 28 && telecom.endCall()) || send(key)
        when (action) {
            "answer" -> if (canTelecom) telecom.acceptRingingCall() else if (!send(Notification.EXTRA_ANSWER_INTENT)) return "failed"
            "decline" -> if (!end(Notification.EXTRA_DECLINE_INTENT)) return "failed"
            "hangup" -> if (!end(Notification.EXTRA_HANG_UP_INTENT)) return "failed"
            "mute", "unmute" -> audio().isMicrophoneMute = action == "mute"
            else -> return "unknown"
        }
        // The computer shows the phone's own state (the microphone can also be muted on the phone).
        if (action == "mute" || action == "unmute") sbn?.let { Bridge.broadcast("pb.x.call", state(it)) }
        return null
    }

    /**
     * Only digits, a leading + and separators. No * or #: those make carrier codes (call forwarding, SIM PIN,
     * USSD) that a computer must not be able to send through the phone's dialer.
     */
    fun cleanNumber(n: String): String? {
        val t = n.trim()
        return if (t.length in 1..32 && t.all { it.isDigit() || it in "+() -." } && t.lastIndexOf('+') <= 0 && t.any { it.isDigit() }) t.filter { it != ' ' && it != '(' && it != ')' && it != '-' && it != '.' } else null
    }

    private fun dial(number: String): String? {
        val n = cleanNumber(number) ?: return "bad_number"
        ctx.getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel", n, null), null)
        return null
    }
}
