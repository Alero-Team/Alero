package dev.alero.app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile «Alero»: opens the app like its launcher icon (as LocalSend and Quick Share do); the user picks what to do. */
class SendTile : TileService() {
    override fun onStartListening() {
        val t = qsTile ?: return
        t.label = "Alero"
        if (Build.VERSION.SDK_INT >= 29) t.subtitle = "Enviar y recibir"
        t.icon = Icon.createWithResource(this, R.drawable.ic_stat_alero)
        t.state = Tile.STATE_ACTIVE
        t.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        // The launcher intent brings an open Alero back as it was instead of pushing a new screen.
        val i = packageManager.getLaunchIntentForPackage(packageName) ?: return
        unlockAndRun {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION") startActivityAndCollapse(i)
            }
        }
    }
}
