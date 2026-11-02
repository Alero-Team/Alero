package dev.alero.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** The only setting Kotlin needs on its own, so it works while the UI is closed. */
object Prefs {
    private fun sp(c: Context) = c.getSharedPreferences("alero", Context.MODE_PRIVATE)
    fun background(c: Context) = sp(c).getBoolean("background", false)
    fun setBackground(c: Context, on: Boolean) = sp(c).edit().putBoolean("background", on).apply()

    /** The owner lets a paired computer browse photos, videos, music and chosen folders. Off by default. */
    fun files(c: Context) = sp(c).getBoolean("files", false)
    fun setFiles(c: Context, on: Boolean) = sp(c).edit().putBoolean("files", on).apply()
}

/** "Detener" on the control notice: the computer ends the session at once. */
class StopControl : android.content.BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        i.getStringExtra(PEER)?.let { Bridge.sendTo(it, "pb.x.phonecontrol.stop", org.json.JSONObject()) }
        c.getSystemService(NotificationManager::class.java).cancel(2)
    }

    companion object { const val PEER = "peer" }
}

/** A silent status notification (the service) and alerts for the things that need the user. */
object Notifier {
    private const val QUIET = "status"
    private const val ALERT = "alerts"
    private var ctx: Context? = null
    private var next = 100

    fun init(c: Context) {
        ctx = c.applicationContext
        val nm = c.getSystemService(NotificationManager::class.java)
        // MIN: no status-bar icon, no sound, collapsed in the shade. Android still lists a foreground service in
        // its task manager, which is why the service only exists while there is something to keep alive.
        nm.createNotificationChannel(NotificationChannel(QUIET, "Conexión con tu ordenador", NotificationManager.IMPORTANCE_MIN).apply {
            setShowBadge(false)
        })
        nm.createNotificationChannel(NotificationChannel(ALERT, "Avisos", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun open(c: Context) = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)

    fun status(c: Context, text: String, connected: Boolean = false): Notification =
        Notification.Builder(c, QUIET)
            .setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle("Alero")
            .setContentText(text)
            .setContentIntent(open(c))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .apply {
                // Opens Alero's file picker for the connected computer (same path as the widgets' Enviar).
                if (connected) addAction(Notification.Action.Builder(null, "Enviar archivo", PendingIntent.getActivity(
                    c, "notice-send".hashCode(),
                    Intent(c, MainActivity::class.java).putExtra(MainActivity.WIDGET, "send")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )).build())
            }
            .build()

    private const val CONTROLLED = 2

    /** While a computer views and drives this phone (scrcpy over adb), an ongoing notice with a way to stop it. */
    fun controlled(peer: String, pc: String, on: Boolean) {
        val c = ctx ?: return
        val nm = c.getSystemService(NotificationManager::class.java)
        if (!on) return nm.cancel(CONTROLLED)
        val stop = PendingIntent.getBroadcast(
            c, 0, Intent(c, StopControl::class.java).putExtra(StopControl.PEER, peer),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(c, ALERT).setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle("$pc controla este teléfono")
            .setContentText("Ve la pantalla y usa el ratón y el teclado.")
            .setContentIntent(open(c)).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Detener", stop).build())
            .build()
        try { nm.notify(CONTROLLED, n) } catch (_: SecurityException) {}
    }

    fun alert(title: String, text: String) {
        val c = ctx ?: return
        val n = Notification.Builder(c, ALERT).setSmallIcon(R.drawable.ic_stat_alero).setContentTitle(title).setContentText(text)
            .setContentIntent(open(c)).setAutoCancel(true).build()
        try {
            c.getSystemService(NotificationManager::class.java).notify(next++, n)
        } catch (_: SecurityException) {
            // notification permission denied: the in-app dialog still shows
        }
    }
}

/**
 * Keeps the process (and the Rust engine in it) alive in the background, but only while it is useful: a paired
 * computer is connected, or the user asked for it in Settings. With the computer off there is no service, no
 * notification and the engine stops announcing itself. Not sticky: the system never revives it on its own.
 */
class PbService : Service() {
    private var wifi: WifiManager.WifiLock? = null
    private var multicast: WifiManager.MulticastLock? = null

    override fun onBind(i: Intent?): IBinder? = null

    /**
     * While the service lives the Wi-Fi radio stays awake and broadcasts reach the engine: with the screen off the
     * phone otherwise stops hearing the computer's announcements and its sockets stall, which looked like random
     * disconnections.
     */
    override fun onCreate() {
        super.onCreate()
        running = true
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifi = wm.createWifiLock(mode, "alero:wifi").apply { setReferenceCounted(false); acquire() }
            multicast = wm.createMulticastLock("alero:multicast").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) {
            // no Wi-Fi (or the system refuses): the connection works as before, just less eagerly
        }
    }

    override fun onDestroy() {
        running = false
        try { wifi?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        try { multicast?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        Notifier.init(this)
        val text = i?.getStringExtra(TEXT) ?: WAITING
        val n = Notifier.status(this, text, connected = text != WAITING)
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        return START_NOT_STICKY
    }

    companion object {
        private const val TEXT = "text"
        private const val WAITING = "Esperando a tu ordenador"
        // After the computer drops the service waits this long for it to come back (a router restart, a roam, the PC
        // waking up). Stopping after 20 s left the process free to be frozen and nothing could reconnect.
        private const val GRACE_MS = 10 * 60_000L
        @Volatile private var running = false
        private val main = Handler(Looper.getMainLooper())
        private var stopper: Runnable? = null

        /** `names`: paired computers connected right now. Called from the engine events and when the setting changes. */
        fun update(c: Context, names: List<String>) {
            val app = c.applicationContext
            main.post {
                stopper?.let(main::removeCallbacks)
                stopper = null
                if (names.isNotEmpty() || Prefs.background(app)) {
                    val text = if (names.isEmpty()) WAITING else "Conectado a ${names.joinToString(", ")}"
                    try {
                        app.startForegroundService(Intent(app, PbService::class.java).putExtra(TEXT, text))
                    } catch (_: Exception) {
                        // Android refuses to start a foreground service from the background in some states: the
                        // connection simply lives as long as the process does.
                    }
                } else {
                    if (running) {
                        // Say so: the notification must not keep claiming a connection that is gone.
                        try {
                            app.startForegroundService(Intent(app, PbService::class.java).putExtra(TEXT, WAITING))
                        } catch (_: Exception) {}
                    }
                    stopper = Runnable { app.stopService(Intent(app, PbService::class.java)) }.also { main.postDelayed(it, GRACE_MS) }
                }
            }
        }
    }
}
