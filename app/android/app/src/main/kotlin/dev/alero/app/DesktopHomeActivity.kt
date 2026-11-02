package dev.alero.app

import android.app.Activity
import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Display
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** Non-privileged launcher for virtual Android displays. Never replaces Pixel HOME. */
class DesktopHomeActivity : Activity() {
    private fun currentDisplayId(): Int = display?.displayId ?: Display.DEFAULT_DISPLAY
    private fun dp(value: Int): Int = (resources.displayMetrics.density * value).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (currentDisplayId() == Display.DEFAULT_DISPLAY) {
            finish()
            return
        }
        buildHome()
    }

    override fun onResume() {
        super.onResume()
        if (currentDisplayId() == Display.DEFAULT_DISPLAY) finish()
    }

    private fun buildHome() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(27, 34, 49))
            setPadding(dp(24), dp(18), dp(24), dp(12))
        }
        root.addView(TextView(this).apply {
            text = "Alero Desktop"
            textSize = 28f
            setTextColor(Color.WHITE)
        })
        root.addView(TextView(this).apply {
            text = "Inicio independiente del Pixel"
            textSize = 15f
            setTextColor(Color.LTGRAY)
            setPadding(0, dp(8), 0, dp(18))
        })
        val grid = GridLayout(this).apply { columnCount = 5 }
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val apps = packageManager.queryIntentActivities(query, 0)
            .filter { it.activityInfo.packageName != packageName }
            .distinctBy { it.activityInfo.packageName }
            .sortedBy { it.loadLabel(packageManager).toString().lowercase() }
        for (app in apps) {
            val info = app.activityInfo
            val name = app.loadLabel(packageManager).toString()
            val tile = Button(this).apply {
                text = name
                textSize = 12f
                isAllCaps = false
                gravity = Gravity.CENTER
                setOnClickListener {
                    val displayId = currentDisplayId()
                    if (displayId == Display.DEFAULT_DISPLAY) return@setOnClickListener
                    try {
                        val launch = Intent(Intent.ACTION_MAIN).apply {
                            addCategory(Intent.CATEGORY_LAUNCHER)
                            component = ComponentName(info.packageName, info.name)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                        }
                        startActivity(launch, ActivityOptions.makeBasic()
                            .apply { launchDisplayId = displayId }.toBundle())
                    } catch (_: Exception) {
                        Toast.makeText(this@DesktopHomeActivity,
                            "Android no permite abrir $name aquí.", Toast.LENGTH_LONG).show()
                    }
                }
            }
            grid.addView(tile, GridLayout.LayoutParams().apply {
                width = dp(160)
                height = dp(74)
                setMargins(dp(4), dp(4), dp(4), dp(4))
            })
        }
        val scroll = ScrollView(this)
        scroll.addView(grid)
        root.addView(scroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }
}
