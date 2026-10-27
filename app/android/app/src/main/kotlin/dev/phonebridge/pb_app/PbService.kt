package dev.phonebridge.pb_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** One quiet ongoing notification (the service) and alerts for things that need the user. */
object Notifier {
    private const val QUIET = "status"
    private const val ALERT = "alerts"
    private var ctx: Context? = null
    private var next = 100

    fun init(c: Context) {
        ctx = c.applicationContext
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(QUIET, "Conexión", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(ALERT, "Avisos", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun open(c: Context) = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)

    fun status(c: Context, text: String): Notification =
        Notification.Builder(c, QUIET)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Phonebridge")
            .setContentText(text)
            .setContentIntent(open(c))
            .setOngoing(true)
            .build()

    fun alert(title: String, text: String) {
        val c = ctx ?: return
        val n = Notification.Builder(c, ALERT).setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle(title).setContentText(text)
            .setContentIntent(open(c)).setAutoCancel(true).build()
        try {
            c.getSystemService(NotificationManager::class.java).notify(next++, n)
        } catch (_: SecurityException) {
            // notification permission denied: the in-app dialog still shows
        }
    }
}

/**
 * Keeps the process alive in the background. The Rust engine lives in the process, so it keeps running even
 * when the Flutter UI is gone; a new UI re-attaches to it.
 */
class PbService : Service() {
    override fun onBind(i: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifier.init(this)
        val n = Notifier.status(this, "Esperando dispositivos emparejados")
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
    }

    override fun onStartCommand(i: Intent?, f: Int, id: Int) = START_STICKY

    companion object {
        fun status(c: Context, text: String) =
            c.getSystemService(NotificationManager::class.java).notify(1, Notifier.status(c, text))
    }
}
