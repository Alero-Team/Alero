package dev.alero.app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile «Alero»: straight to picking files for the connected computer (the widgets' «send»). */
class SendTile : TileService() {
    override fun onStartListening() {
        val t = qsTile ?: return
        t.label = "Alero"
        if (Build.VERSION.SDK_INT >= 29) t.subtitle = Tr.t("Enviar archivos", "Send files")
        t.icon = Icon.createWithResource(this, R.drawable.ic_stat_alero)
        t.state = Tile.STATE_ACTIVE
        t.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        // The widgets' «send»: the file picker opens at once and the files go to the connected computer (or Alero
        // says it is not connected). SINGLE_TOP: an open Alero gets it in onNewIntent instead of a second screen.
        val i = Intent(this, MainActivity::class.java).putExtra(MainActivity.WIDGET, "send")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        unlockAndRun {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, "tile-send".hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            } else {
                @Suppress("DEPRECATION") startActivityAndCollapse(i)
            }
        }
    }
}
