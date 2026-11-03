package dev.alero.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The phone's SMS and MMS for a paired computer (`pb.x.sms.*`). Off until the owner turns it on in Settings and
 * grants Android's SMS permission; contact names need the contacts permission (numbers are shown without it).
 * Alero is not the default SMS app: it reads the system's message store and sends through SmsManager, and
 * Android itself records the sent message in the conversation.
 */
object Sms {
    private lateinit var ctx: Context
    private val pool = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val watchers = ConcurrentHashMap<String, Long>()
    private var observer: ContentObserver? = null
    private val threadsUri: Uri = Uri.parse("content://mms-sms/conversations?simple=true")
    private val addressesUri: Uri = Uri.parse("content://mms-sms/canonical-addresses")
    private const val THREADS = 150
    private const val MESSAGES = 120
    private const val BUDGET = 200_000 // bytes of JSON per message: the frame limit is 256 KiB

    val permissions = arrayOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.READ_CONTACTS)

    fun init(c: Context) {
        ctx = c.applicationContext
    }

    private fun has(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    fun readable() = has(Manifest.permission.READ_SMS)
    fun allowed() = Prefs.sms(ctx) && readable()

    fun handle(peer: String, kind: String, body: JSONObject) {
        if (!allowed()) {
            Bridge.sendTo(peer, "pb.x.sms.denied", JSONObject().put("reason", if (Prefs.sms(ctx)) "no_permission" else "not_allowed"))
            return
        }
        watchers[peer] = System.currentTimeMillis()
        main.post { watch() }
        pool.execute {
            try {
                when (kind) {
                    "pb.x.sms.threads.request" -> Bridge.sendTo(peer, "pb.x.sms.threads", JSONObject().put("items", threads()))
                    "pb.x.sms.thread" -> body.optLong("thread", -1).takeIf { it >= 0 }?.let {
                        Bridge.sendTo(peer, "pb.x.sms.messages", JSONObject().put("thread", it).put("items", messages(it)))
                    }
                    "pb.x.sms.send" -> Bridge.sendTo(peer, "pb.x.sms.sent", send(body))
                }
            } catch (_: SecurityException) {
                Bridge.sendTo(peer, "pb.x.sms.denied", JSONObject().put("reason", "no_permission"))
            } catch (_: Exception) {
                // a bad request from a paired device must not stop the service
            }
        }
    }

    // --- reading ----------------------------------------------------------------------------------------

    private fun addresses(): Map<String, String> {
        val out = HashMap<String, String>()
        ctx.contentResolver.query(addressesUri, arrayOf("_id", "address"), null, null, null)?.use { c ->
            while (c.moveToNext()) out[c.getString(0)] = c.getString(1) ?: ""
        }
        return out
    }

    private val names = HashMap<String, String>()

    /** The contact's name for a number, or the number itself. */
    private fun name(address: String): String {
        if (address.isEmpty() || !has(Manifest.permission.READ_CONTACTS)) return address
        return synchronized(names) { names[address] } ?: run {
            val n = try {
                ctx.contentResolver.query(
                    Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)),
                    arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
                )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
            } catch (_: Exception) { null } ?: address
            synchronized(names) { if (names.size > 500) names.clear(); names[address] = n }
            n
        }
    }

    private fun threadAddresses(thread: Long, all: Map<String, String> = addresses()): List<String> =
        ctx.contentResolver.query(threadsUri, arrayOf("recipient_ids"), "_id = ?", arrayOf(thread.toString()), null)?.use { c ->
            if (c.moveToFirst()) (c.getString(0) ?: "").split(' ').mapNotNull { all[it]?.takeIf { a -> a.isNotEmpty() } } else emptyList()
        } ?: emptyList()

    private fun threads(): JSONArray {
        val all = addresses()
        val a = JSONArray()
        ctx.contentResolver.query(threadsUri, arrayOf("_id", "date", "message_count", "recipient_ids", "snippet", "read"), null, null, "date DESC")?.use { c ->
            while (c.moveToNext() && a.length() < THREADS) {
                if (c.getInt(2) == 0) continue
                val who = (c.getString(3) ?: "").split(' ').mapNotNull { all[it]?.takeIf { x -> x.isNotEmpty() } }
                a.put(JSONObject()
                    .put("thread", c.getLong(0))
                    .put("date", c.getLong(1))
                    .put("count", c.getInt(2))
                    .put("addresses", JSONArray(who))
                    .put("name", who.joinToString(", ") { name(it) })
                    .put("snippet", (c.getString(4) ?: "").take(160))
                    .put("read", c.getInt(5) != 0))
            }
        }
        return a
    }

    private fun messages(thread: Long): JSONArray {
        val items = ArrayList<JSONObject>()
        ctx.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(thread.toString()), "${Telephony.Sms.DATE} DESC",
        )?.use { c ->
            while (c.moveToNext() && items.size < MESSAGES) {
                val type = c.getInt(4)
                items += msg("s${c.getLong(0)}", c.getString(2) ?: "", c.getLong(3), type != Telephony.Sms.MESSAGE_TYPE_INBOX,
                    c.getString(1) ?: "", 0, type == Telephony.Sms.MESSAGE_TYPE_FAILED)
            }
        }
        ctx.contentResolver.query(
            Telephony.Mms.CONTENT_URI, arrayOf(Telephony.Mms._ID, Telephony.Mms.DATE, Telephony.Mms.MESSAGE_BOX),
            "${Telephony.Mms.THREAD_ID} = ?", arrayOf(thread.toString()), "${Telephony.Mms.DATE} DESC",
        )?.use { c ->
            var n = 0
            while (c.moveToNext() && n++ < MESSAGES) {
                val id = c.getLong(0)
                val (text, media) = mmsParts(id)
                val out = c.getInt(2) != Telephony.Mms.MESSAGE_BOX_INBOX
                items += msg("m$id", text, c.getLong(1) * 1000, out, if (out) "" else mmsSender(id), media, false)
            }
        }
        // Newest MESSAGES, oldest first, within the frame budget.
        val newest = items.sortedByDescending { it.getLong("date") }.take(MESSAGES)
        val kept = ArrayList<JSONObject>()
        var size = 0
        for (m in newest) {
            size += m.toString().length
            if (size > BUDGET) break
            kept += m
        }
        return JSONArray(kept.reversed())
    }

    private fun msg(id: String, body: String, date: Long, out: Boolean, sender: String, media: Int, failed: Boolean) =
        JSONObject().put("id", id).put("body", body.take(4000)).put("date", date).put("out", out)
            .put("sender", if (out) "" else name(sender)).put("media", media).put("failed", failed)

    /** Text of an MMS and how many attachments (pictures, audio…) it carries; the attachments stay on the phone. */
    private fun mmsParts(id: Long): Pair<String, Int> {
        val text = StringBuilder()
        var media = 0
        ctx.contentResolver.query(Uri.parse("content://mms/part"), arrayOf("ct", "text"), "mid = ?", arrayOf(id.toString()), null)?.use { c ->
            while (c.moveToNext()) {
                val ct = c.getString(0) ?: ""
                when {
                    ct == "text/plain" -> c.getString(1)?.let { if (text.isNotEmpty()) text.append('\n'); text.append(it) }
                    ct == "application/smil" -> {}
                    else -> media++
                }
            }
        }
        return text.toString() to media
    }

    private fun mmsSender(id: Long): String =
        ctx.contentResolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address"), "type = 137", null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) ?: "" else ""
        } ?: ""

    // --- sending ----------------------------------------------------------------------------------------

    /** Sends a text to a one-person conversation. Group conversations need MMS, which only the default SMS app can send. */
    private fun send(b: JSONObject): JSONObject {
        val r = JSONObject().put("request", b.optString("request").take(200)).put("thread", b.optLong("thread"))
        fun fail(e: String) = r.put("ok", false).put("error", e)
        val text = b.optString("text")
        if (text.isBlank()) return fail("empty")
        if (!has(Manifest.permission.SEND_SMS)) return fail("no_permission")
        val to = threadAddresses(b.optLong("thread", -1))
        if (to.isEmpty()) return fail("no_thread")
        if (to.size > 1) return fail("group")
        val sm: SmsManager = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java)
            else @Suppress("DEPRECATION") SmsManager.getDefault()
        return try {
            sm.sendMultipartTextMessage(to[0], null, sm.divideMessage(text), null, null)
            r.put("ok", true)
        } catch (_: Exception) { fail("send_failed") }
    }

    // --- tell the computer when messages change ---------------------------------------------------------

    private fun watch() {
        if (observer != null) return
        val o = object : ContentObserver(main) {
            private val tell = Runnable {
                watchers.entries.removeIf { System.currentTimeMillis() - it.value > 600_000 }
                if (watchers.isEmpty()) {
                    ctx.contentResolver.unregisterContentObserver(this)
                    observer = null
                } else {
                    watchers.keys.forEach { Bridge.sendTo(it, "pb.x.sms.changed", JSONObject()) }
                }
            }

            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(tell)
                main.postDelayed(tell, 1200)
            }
        }
        observer = o
        ctx.contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, o)
    }
}
