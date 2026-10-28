package dev.alero.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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

    fun status(c: Context, text: String): Notification =
        Notification.Builder(c, QUIET)
            .setSmallIcon(R.drawable.ic_stat_alero)
            .setContentTitle("Alero")
            .setContentText(text)
            .setContentIntent(open(c))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

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
    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        Notifier.init(this)
        val n = Notifier.status(this, i?.getStringExtra(TEXT) ?: WAITING)
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        return START_NOT_STICKY
    }

    companion object {
        private const val TEXT = "text"
        private const val WAITING = "Esperando a tu ordenador"
        private const val GRACE_MS = 20_000L // a Wi-Fi blip must not make the notification flicker
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
                    stopper = Runnable { app.stopService(Intent(app, PbService::class.java)) }.also { main.postDelayed(it, GRACE_MS) }
                }
            }
        }
    }
}
