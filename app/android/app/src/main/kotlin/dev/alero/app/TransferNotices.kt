package dev.alero.app

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import org.json.JSONObject

/**
 * Transfers in the notification shade, from the engine's own events: an incoming file waiting for consent
 * (Aceptar / Rechazar), live progress with Cancelar, and the result with a way to open it. Nothing is
 * accepted, downloaded or opened without the user's tap; the engine ignores a second answer.
 */
object TransferNotices {
    private const val CHANNEL = "transfers"
    private const val ALERT = "alerts" // Notifier's channel: an offer and a finished file deserve a sound
    private var ctx: Context? = null
    private data class Info(val name: String, val incoming: Boolean, val peer: String, var drawn: Long = 0)
    private val live = HashMap<String, Info>()

    fun init(c: Context) {
        if (ctx != null) return
        ctx = c.applicationContext
        Notifier.init(c)
        c.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Transferencias", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
    }

    fun nid(id: String) = 0x4000_0000 or (id.hashCode() and 0x0FFF_FFFF)

    private fun nm(c: Context) = c.getSystemService(NotificationManager::class.java)

    private fun notify(c: Context, id: Int, n: Notification) {
        try { nm(c).notify(id, n) } catch (_: SecurityException) { /* notifications denied: the app still shows it */ }
    }

    private fun act(c: Context, id: String, what: String, label: String): Notification.Action {
        val pi = PendingIntent.getBroadcast(
            c, (id + what).hashCode(),
            Intent(c, TransferAction::class.java).putExtra(TransferAction.ID, id).putExtra(TransferAction.WHAT, what),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Action.Builder(null, label, pi).build()
    }

    /** Alero at a section (same path as the widgets: MainActivity.WIDGET). */
    private fun openApp(c: Context, section: String) = PendingIntent.getActivity(
        c, ("open-$section").hashCode(),
        Intent(c, MainActivity::class.java).putExtra(MainActivity.WIDGET, section)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun offer(e: JSONObject) {
        val c = ctx ?: return
        val id = e.getString("id")
        synchronized(live) { live[id] = Info(e.optString("name"), true, e.optString("peer_name")) }
        val n = Notification.Builder(c, ALERT).setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle("${e.optString("peer_name").ifEmpty { "Un dispositivo" }} quiere enviarte un archivo")
            .setContentText("${e.optString("name")} · ${WidgetText.size(e.optLong("size"))}")
            .setContentIntent(openApp(c, "files"))
            .setAutoCancel(true)
            .setTimeoutAfter(120_000) // the engine drops an unanswered offer after two minutes
            .addAction(act(c, id, TransferAction.DECLINE, "Rechazar"))
            .addAction(act(c, id, TransferAction.ACCEPT, "Aceptar descarga"))
            .build()
        notify(c, nid(id), n)
    }

    fun started(e: JSONObject) {
        val id = e.getString("id")
        synchronized(live) { live[id] = Info(e.optString("name"), e.optBoolean("incoming"), e.optString("peer_name")) }
        progress(id, 0, e.optLong("size"), force = true)
    }

    /** At most one redraw a second per transfer: progress events come much faster. */
    fun progress(id: String, done: Long, total: Long, force: Boolean = false) {
        val c = ctx ?: return
        val info = synchronized(live) { live[id] } ?: return
        val now = SystemClock.elapsedRealtime()
        if (!force && now - info.drawn < 1000) return
        info.drawn = now
        val n = Notification.Builder(c, CHANNEL).setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle((if (info.incoming) "Recibiendo " else "Enviando ") + info.name)
            .setContentText(if (total > 0) "${WidgetText.size(done)} de ${WidgetText.size(total)}" else info.peer)
            .setProgress(1000, if (total > 0) (done * 1000 / total).toInt() else 0, total <= 0)
            .setOngoing(true).setOnlyAlertOnce(true)
            .setContentIntent(openApp(c, "files"))
            .addAction(act(c, id, TransferAction.CANCEL, "Cancelar"))
            .build()
        notify(c, nid(id), n)
    }

    fun finished(e: JSONObject) {
        val c = ctx ?: return
        val id = e.getString("id")
        val info = synchronized(live) { live.remove(id) }
        nm(c).cancel(nid(id))
        info ?: return
        val ok = e.optBoolean("ok")
        if (!ok && e.optString("code") == "CANCELLED") return
        val b = Notification.Builder(c, ALERT).setSmallIcon(R.drawable.ic_stat_alero).setAutoCancel(true)
            .setContentIntent(openApp(c, "files"))
        if (ok && info.incoming) {
            b.setContentTitle("Archivo recibido").setContentText(info.name)
                .addAction(Notification.Action.Builder(null, "Abrir en Alero", openApp(c, "files")).build())
                .addAction(Notification.Action.Builder(null, "Descargas", PendingIntent.getActivity(
                    c, "downloads".hashCode(),
                    Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE,
                )).build())
        } else if (ok) {
            return // a sent file needs no second notice: the progress one just closed
        } else {
            b.setContentTitle("No se completó la transferencia").setContentText(info.name)
        }
        notify(c, nid(id), b.build())
    }
}

/** Aceptar / Rechazar / Cancelar from a transfer notification. */
class TransferAction : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val id = i.getStringExtra(ID) ?: return
        // Close the offer first, so a second tap has nothing to press.
        if (i.getStringExtra(WHAT) != CANCEL) c.getSystemService(NotificationManager::class.java).cancel(TransferNotices.nid(id))
        try {
            when (i.getStringExtra(WHAT)) {
                ACCEPT -> Bridge.respondTransfer(id, true)
                DECLINE -> Bridge.respondTransfer(id, false)
                CANCEL -> Bridge.cancelTransfer(id)
            }
        } catch (_: Throwable) {
            // engine not running: the offer or transfer is already gone
        }
    }

    companion object {
        const val ID = "id"
        const val WHAT = "what"
        const val ACCEPT = "accept"
        const val DECLINE = "decline"
        const val CANCEL = "cancel"
    }
}
