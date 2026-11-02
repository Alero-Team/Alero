package dev.alero.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen widgets (AppWidget + RemoteViews: no Compose runtime in the APK). They show only what the engine
 * reports — paired computers, their battery, transfers, what the computer plays — and are redrawn when that
 * changes (at most once a second), never on a timer. The last state is kept on disk, so a widget drawn after
 * the process died shows it as "sin conexión" instead of stale "conectado".
 */
object WidgetData {
    /** A paired computer as the widgets draw it. */
    data class Pc(val id: String, var name: String, var online: Boolean, var battery: Int = -1, var charging: Boolean = false)

    data class Transfer(val id: String, val name: String, val incoming: Boolean, var done: Long, val total: Long, var status: String)

    data class Media(val title: String, val artist: String, val app: String, val playing: Boolean, val actions: Long)

    private val pcs = LinkedHashMap<String, Pc>()
    /** Newest first; the widgets show the active one and the two before it. */
    private val transfers = ArrayList<Transfer>()
    private val transfer get() = transfers.firstOrNull()
    private var media: Media? = null
    private var ctx: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private var pending = false
    private var lastDraw = 0L
    private var watchedAt = 0L

    fun init(c: Context) {
        if (ctx != null) return
        ctx = c.applicationContext
        load()
        // A new process has no connection yet: the engine reports each computer again when it connects.
        synchronized(this) { pcs.values.forEach { it.online = false } }
        changed()
    }

    // --- engine events (called from Features' loop) -----------------------------------------------------

    fun peer(id: String, name: String, online: Boolean) = edit {
        val p = pcs.getOrPut(id) { Pc(id, name, online) }
        if (name.isNotEmpty()) p.name = name
        p.online = online
        if (!online) media = null
    }

    fun forget(id: String) = edit { pcs.remove(id) }

    /** `pb.x.info` from a computer: its battery. */
    fun info(id: String, b: JSONObject) = edit {
        val p = pcs[id] ?: return@edit
        val bat = b.optJSONObject("battery")
        p.battery = bat?.optInt("level", -1) ?: -1
        p.charging = bat?.optBoolean("charging") ?: false
    }

    fun transferStarted(e: JSONObject) = edit {
        transfers.removeAll { it.id == e.getString("id") }
        transfers.add(0, Transfer(e.getString("id"), e.optString("name"), e.optBoolean("incoming"), 0, e.optLong("size"), "running"))
        while (transfers.size > 3) transfers.removeAt(transfers.size - 1)
    }

    fun transferProgress(e: JSONObject) {
        val t = synchronized(this) { transfers.firstOrNull { it.id == e.optString("id") } } ?: return
        t.done = e.optLong("done")
        changed()
    }

    fun transferFinished(e: JSONObject) = edit {
        val t = transfers.firstOrNull { it.id == e.optString("id") } ?: return@edit
        t.status = if (e.optBoolean("ok")) "done" else if (e.optString("code") == "CANCELLED") "cancelled" else "failed"
        if (t.status == "done") t.done = t.total
    }

    /** `pb.x.pcmedia.state` from a computer. */
    fun media(b: JSONObject) = edit {
        media = if (!b.optBoolean("active")) null else Media(
            b.optString("title"), b.optString("artist"), b.optString("app"), b.optBoolean("playing"), b.optLong("actions"),
        )
    }

    /** Called every few seconds by Features: keeps the computer's media coming only while a widget shows it. */
    fun tick() {
        val c = ctx ?: return
        val pc = firstOnline() ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - watchedAt < 20_000) return
        if (ids(c, MediaWidget::class.java).isEmpty() && ids(c, PanelWidget::class.java).isEmpty()) return
        watchedAt = now
        Bridge.sendTo(pc.id, "pb.x.pcmedia.watch", JSONObject())
    }

    fun firstOnline(): Pc? = synchronized(this) { pcs.values.firstOrNull { it.online } }

    // --- drawing -----------------------------------------------------------------------------------------

    private inline fun edit(f: () -> Unit) {
        synchronized(this) { f() }
        changed()
    }

    /** Coalesces bursts (transfer progress) into one redraw per second. */
    fun changed() {
        synchronized(this) {
            if (pending) return
            pending = true
        }
        val wait = (1000 - (SystemClock.elapsedRealtime() - lastDraw)).coerceIn(0, 1000)
        main.postDelayed({
            synchronized(this) { pending = false }
            lastDraw = SystemClock.elapsedRealtime()
            save()
            drawAll()
        }, wait)
    }

    fun drawAll() {
        val c = ctx ?: return
        for (k in kinds) {
            val m = AppWidgetManager.getInstance(c)
            for (id in ids(c, k)) m.updateAppWidget(id, views(c, k, m.getAppWidgetOptions(id)))
        }
    }

    private val kinds = listOf(
        DevicesWidget::class.java, StatusWidget::class.java, ActionsWidget::class.java,
        TransferWidget::class.java, MediaWidget::class.java, PanelWidget::class.java,
    )

    private fun ids(c: Context, k: Class<*>) = AppWidgetManager.getInstance(c).getAppWidgetIds(ComponentName(c, k))

    fun views(c: Context, k: Class<*>, opts: Bundle?): RemoteViews = synchronized(this) {
        when (k) {
            DevicesWidget::class.java -> devices(c)
            StatusWidget::class.java -> status(c)
            ActionsWidget::class.java -> actions(c, R.layout.widget_actions)
            TransferWidget::class.java -> transfer(c, R.layout.widget_transfer)
            MediaWidget::class.java -> media(c, R.layout.widget_media)
            else -> panel(c, opts)
        }
    }

    /** Opens Alero at `action` (see Hub.widgetAction on the Dart side). */
    private fun open(c: Context, action: String): PendingIntent = PendingIntent.getActivity(
        c, action.hashCode(),
        Intent(c, MainActivity::class.java).putExtra(MainActivity.WIDGET, action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun mediaKey(c: Context, action: String): PendingIntent = PendingIntent.getBroadcast(
        c, action.hashCode(), Intent(c, WidgetMedia::class.java).putExtra(WidgetMedia.ACTION, action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun batteryText(level: Int, charging: Boolean) = WidgetText.battery(level, charging)
    private fun stateText(p: Pc) = WidgetText.state(p.online, p.battery, p.charging)
    private fun human(b: Long) = WidgetText.size(b)

    private fun devices(c: Context) = RemoteViews(c.packageName, R.layout.widget_devices).apply {
        setOnClickPendingIntent(R.id.root, open(c, "devices"))
        val list = pcs.values.take(3)
        val rows = listOf(Triple(R.id.row1, R.id.name1, R.id.state1), Triple(R.id.row2, R.id.name2, R.id.state2), Triple(R.id.row3, R.id.name3, R.id.state3))
        rows.forEachIndexed { i, (row, name, state) ->
            val p = list.getOrNull(i)
            setViewVisibility(row, if (p == null) View.GONE else View.VISIBLE)
            if (p != null) {
                setTextViewText(name, p.name)
                setTextViewText(state, stateText(p))
            }
        }
        setViewVisibility(R.id.empty, if (list.isEmpty()) View.VISIBLE else View.GONE)
    }

    private fun status(c: Context) = RemoteViews(c.packageName, R.layout.widget_status).apply {
        setOnClickPendingIntent(R.id.root, open(c, "home"))
        val p = firstOnline() ?: pcs.values.firstOrNull()
        setTextViewText(R.id.title, p?.name ?: "Sin ordenador")
        setTextViewText(R.id.state, p?.let(::stateText) ?: "Empareja un ordenador en Alero")
        val (level, charging) = Features.phoneBattery()
        setTextViewText(R.id.phone, "Este teléfono: " + batteryText(level, charging).ifEmpty { "—" })
        setProgressBar(R.id.battery, 100, p?.battery?.coerceAtLeast(0) ?: 0, false)
        setViewVisibility(R.id.battery, if (p != null && p.online && p.battery >= 0) View.VISIBLE else View.GONE)
    }

    private fun actions(c: Context, layout: Int) = RemoteViews(c.packageName, layout).apply {
        val p = firstOnline() ?: pcs.values.firstOrNull()
        setTextViewText(R.id.a_status, p?.let { "${it.name} · ${stateText(it)}" } ?: "Sin ordenador emparejado")
        setOnClickPendingIntent(R.id.a_connect, open(c, "devices"))
        setOnClickPendingIntent(R.id.a_send, open(c, "send"))
        setOnClickPendingIntent(R.id.a_files, open(c, "files"))
        setOnClickPendingIntent(R.id.a_clip, open(c, "clip"))
        setOnClickPendingIntent(R.id.a_control, open(c, "control"))
        setOnClickPendingIntent(R.id.a_screen, open(c, "screen"))
    }

    private fun transfer(c: Context, layout: Int) = RemoteViews(c.packageName, layout).apply {
        setOnClickPendingIntent(R.id.t_root, open(c, "home"))
        setOnClickPendingIntent(R.id.t_send, open(c, "send"))
        val older = transfers.drop(1).joinToString("\n") { WidgetText.recent(it.name, it.incoming, it.status) }
        setTextViewText(R.id.t_recent, older)
        setViewVisibility(R.id.t_recent, if (older.isEmpty()) View.GONE else View.VISIBLE)
        val t = transfer
        if (t == null) {
            setTextViewText(R.id.t_name, "Sin transferencias")
            setTextViewText(R.id.t_state, "Los archivos que envíes o recibas aparecerán aquí")
            setViewVisibility(R.id.t_progress, View.GONE)
            return@apply
        }
        setTextViewText(R.id.t_name, t.name)
        val size = "${human(t.done)} de ${human(t.total)}"
        setTextViewText(R.id.t_state, when (t.status) {
            "running" -> (if (t.incoming) "Recibiendo · " else "Enviando · ") + size
            "done" -> (if (t.incoming) "Recibido · " else "Enviado · ") + human(t.total)
            "cancelled" -> "Cancelado"
            else -> "Falló · $size"
        })
        setViewVisibility(R.id.t_progress, if (t.status == "running") View.VISIBLE else View.GONE)
        setProgressBar(R.id.t_progress, 1000, if (t.total > 0) (t.done * 1000 / t.total).toInt() else 0, false)
    }

    private fun media(c: Context, layout: Int) = RemoteViews(c.packageName, layout).apply {
        setOnClickPendingIntent(R.id.m_root, open(c, "home"))
        val m = media
        val pc = firstOnline()
        setTextViewText(R.id.m_title, m?.title?.ifEmpty { null } ?: if (pc == null) "Sin conexión" else "No suena nada")
        setTextViewText(R.id.m_artist, m?.let { listOf(it.artist, appName(it.app)).filter(String::isNotEmpty).joinToString(" · ") }
            ?: (pc?.let { "En ${it.name}" } ?: "Conecta tu ordenador"))
        setImageViewResource(R.id.m_play, if (m?.playing == true) R.drawable.ic_w_pause else R.drawable.ic_w_play)
        setContentDescription(R.id.m_play, if (m?.playing == true) "Pausar" else "Reproducir")
        // The bits are the computer's own (sys::media_state): 16 previous, 32 next, 2/4/512 pause/play/toggle.
        val a = m?.actions ?: 0
        setViewVisibility(R.id.m_prev, if (a and 16L != 0L) View.VISIBLE else View.INVISIBLE)
        setViewVisibility(R.id.m_next, if (a and 32L != 0L) View.VISIBLE else View.INVISIBLE)
        setViewVisibility(R.id.m_play, if (m != null) View.VISIBLE else View.INVISIBLE)
        // Without a connected computer there is nothing to press: the buttons open Alero instead.
        fun key(a: String) = if (pc == null) open(c, "home") else mediaKey(c, a)
        setOnClickPendingIntent(R.id.m_prev, key("prev"))
        setOnClickPendingIntent(R.id.m_play, key("toggle"))
        setOnClickPendingIntent(R.id.m_next, key("next"))
    }

    /** The large panel: one layout per size band, so nothing is clipped when it is resized. */
    private fun panel(c: Context, opts: Bundle?): RemoteViews {
        fun build(layout: Int) = RemoteViews(c.packageName, layout).apply {
            setOnClickPendingIntent(R.id.root, open(c, "home"))
            val p = firstOnline() ?: pcs.values.firstOrNull()
            setTextViewText(R.id.title, p?.name ?: "Sin ordenador")
            setTextViewText(R.id.state, p?.let(::stateText) ?: "Empareja un ordenador en Alero")
            val t = transfer
            setTextViewText(R.id.t_name, t?.name ?: "Sin transferencias")
            setTextViewText(R.id.t_state, t?.let { if (it.status == "running") "${human(it.done)} de ${human(it.total)}" else if (it.status == "done") "Completado" else "Sin terminar" } ?: "")
            setViewVisibility(R.id.t_progress, if (t?.status == "running") View.VISIBLE else View.GONE)
            setProgressBar(R.id.t_progress, 1000, if (t != null && t.total > 0) (t.done * 1000 / t.total).toInt() else 0, false)
            setOnClickPendingIntent(R.id.a_send, open(c, "send"))
            setOnClickPendingIntent(R.id.a_clip, open(c, "clip"))
            setOnClickPendingIntent(R.id.a_control, open(c, "control"))
            setOnClickPendingIntent(R.id.a_screen, open(c, "screen"))
        }
        val small = build(R.layout.widget_panel_small)
        val large = build(R.layout.widget_panel)
        if (Build.VERSION.SDK_INT >= 31) {
            return RemoteViews(mapOf(SizeF(180f, 110f) to small, SizeF(250f, 200f) to large))
        }
        val h = opts?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
        return if (h >= 200) large else small
    }

    private fun appName(aumid: String): String = aumid.substringAfterLast('!').substringBefore('.').let {
        // A Windows AppUserModelID ("Spotify.exe", "Microsoft.ZuneMusic_8wek…!Microsoft.ZuneMusic"): its readable part.
        if (it.length > 24) "" else it
    }

    // --- cache ---------------------------------------------------------------------------------------------

    private fun prefs() = ctx!!.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    private fun save() = synchronized(this) {
        val o = JSONObject()
        o.put("pcs", org.json.JSONArray().apply {
            pcs.values.forEach { put(JSONObject().put("id", it.id).put("name", it.name).put("battery", it.battery).put("charging", it.charging)) }
        })
        // A transfer still running when the process dies did not finish: stored as failed.
        o.put("transfers", org.json.JSONArray().apply {
            transfers.forEach { put(JSONObject().put("id", it.id).put("name", it.name).put("incoming", it.incoming).put("done", it.done).put("total", it.total).put("status", if (it.status == "running") "failed" else it.status)) }
        })
        prefs().edit().putString("state", o.toString()).apply()
    }

    private fun load() {
        val o = try { JSONObject(prefs().getString("state", null) ?: return) } catch (_: Exception) { return }
        val a = o.optJSONArray("pcs") ?: org.json.JSONArray()
        for (i in 0 until a.length()) a.getJSONObject(i).let {
            pcs[it.getString("id")] = Pc(it.getString("id"), it.optString("name"), false, it.optInt("battery", -1), it.optBoolean("charging"))
        }
        val t = o.optJSONArray("transfers") ?: org.json.JSONArray()
        for (i in 0 until minOf(t.length(), 3)) t.getJSONObject(i).let {
            transfers.add(Transfer(it.getString("id"), it.optString("name"), it.optBoolean("incoming"), it.optLong("done"), it.optLong("total"), it.optString("status")))
        }
    }
}

/** The widgets' wording, kept apart from Android so it can be unit-tested. */
object WidgetText {
    fun battery(level: Int, charging: Boolean): String =
        if (level < 0) "" else "$level %" + if (charging) " · cargando" else ""

    fun state(online: Boolean, level: Int, charging: Boolean): String =
        if (!online) "Sin conexión" else listOf("Conectado", battery(level, charging)).filter { it.isNotEmpty() }.joinToString(" · ")

    /** One line of the transfer widget's history. */
    fun recent(name: String, incoming: Boolean, status: String): String = when (status) {
        "done" -> if (incoming) "Recibido" else "Enviado"
        "cancelled" -> "Cancelado"
        "running" -> if (incoming) "Recibiendo" else "Enviando"
        else -> "Falló"
    } + " · " + name

    fun size(b: Long): String = when {
        b >= 1L shl 30 -> String.format(java.util.Locale.ROOT, "%.1f GB", b / (1L shl 30).toDouble())
        b >= 1L shl 20 -> String.format(java.util.Locale.ROOT, "%.1f MB", b / (1L shl 20).toDouble())
        b >= 1L shl 10 -> "${b shr 10} KB"
        else -> "$b B"
    }
}

/** One provider class per widget kind; all of them draw from [WidgetData]. */
open class AleroWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, m: AppWidgetManager, ids: IntArray) {
        WidgetData.init(c)
        for (id in ids) m.updateAppWidget(id, WidgetData.views(c, javaClass, m.getAppWidgetOptions(id)))
    }

    override fun onAppWidgetOptionsChanged(c: Context, m: AppWidgetManager, id: Int, opts: Bundle) {
        WidgetData.init(c)
        m.updateAppWidget(id, WidgetData.views(c, javaClass, opts))
    }
}

class DevicesWidget : AleroWidget()
class StatusWidget : AleroWidget()
class ActionsWidget : AleroWidget()
class TransferWidget : AleroWidget()
class MediaWidget : AleroWidget()
class PanelWidget : AleroWidget()

/** Media buttons: sent to the connected computer as its own media keys (`pb.x.remote.media`). */
class WidgetMedia : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val action = i.getStringExtra(ACTION) ?: return
        val pc = WidgetData.firstOnline() ?: return
        try {
            Bridge.sendTo(pc.id, "pb.x.remote.media", JSONObject().put("action", action))
        } catch (_: Throwable) {
            // engine not loaded: nothing to send to
        }
    }

    companion object { const val ACTION = "action" }
}
