package dev.alero.app

import android.app.Activity
import android.app.ActivityOptions
import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ResolveInfo
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.view.Display
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.BaseAdapter
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.GridView
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextClock
import android.widget.TextView
import android.widget.Toast
import android.window.OnBackInvokedDispatcher
import java.io.File

/**
 * Alero's desktop on a virtual Android display (the Deck mode): wallpaper, clock, a taskbar with pinned apps,
 * battery and time, and a start menu with search. Apps open on this display, in their own windows when the
 * phone supports desktop windowing. Non-privileged: it never replaces the phone's own HOME.
 *
 * Android ignores Home on scrcpy's displays, so the taskbar has Alero's own Home button. With "display over
 * other apps" (the computer grants it over adb) the taskbar floats above apps and shrinks to a thin strip
 * while an app is in front; the mouse over the strip brings it back.
 */
class DesktopHomeActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var taskbarApps: LinearLayout
    private lateinit var taskbarView: View
    private lateinit var battery: TextView
    private lateinit var menu: FrameLayout
    private lateinit var search: EditText
    private val adapter = AppsAdapter()
    private var dock: Dock? = null
    private var up = false
    private val collapse = Runnable { if (!up) dock?.expand(false) }
    private var apps: List<ResolveInfo> = emptyList()
    private val prefs by lazy { getSharedPreferences("desktop", MODE_PRIVATE) }
    private val tick = object : Runnable {
        override fun run() {
            updateBattery()
            main.postDelayed(this, 60_000)
        }
    }

    // Activity.getDisplay() is API 30; below that the window manager's display is this activity's.
    private fun currentDisplayId(): Int =
        if (Build.VERSION.SDK_INT >= 30) display?.displayId ?: Display.DEFAULT_DISPLAY
        else @Suppress("DEPRECATION") windowManager.defaultDisplay.displayId
    private fun dp(value: Int): Int = (resources.displayMetrics.density * value).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (currentDisplayId() == Display.DEFAULT_DISPLAY) {
            finish()
            return
        }
        setContentView(buildDesktop())
        floatTaskbar()
        // Back on the desktop has nothing to return to: closing it would leave a black display. It closes the menu.
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { showMenu(false) }
        }
    }

    @Deprecated("Kept for Android 12 and older")
    override fun onBackPressed() = showMenu(false)

    override fun onResume() {
        super.onResume()
        if (currentDisplayId() == Display.DEFAULT_DISPLAY) return finish()
        up = true
        main.removeCallbacks(collapse)
        dock?.expand(true)
        loadApps()
        main.post(tick)
    }

    override fun onPause() {
        super.onPause()
        up = false
        main.postDelayed(collapse, 1500)
        main.removeCallbacks(tick)
    }

    override fun onDestroy() {
        main.removeCallbacks(collapse)
        dock?.let { d -> try { d.wm.removeView(d) } catch (_: Exception) {} }
        dock = null
        super.onDestroy()
    }

    /** Brings this desktop back to the front of its display (Alero's Home). */
    private fun goHome(menu: Boolean = false) {
        if (up) return showMenu(menu)
        try {
            startActivity(
                Intent(this, DesktopHomeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    .putExtra("menu", menu),
                ActivityOptions.makeBasic().apply { launchDisplayId = currentDisplayId() }.toBundle(),
            )
        } catch (_: Exception) {}
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showMenu(intent.getBooleanExtra("menu", false))
    }

    /** Moves the taskbar out of the activity into an overlay window on this display, when Android allows it. */
    private fun floatTaskbar() {
        if (Build.VERSION.SDK_INT < 30 || !Settings.canDrawOverlays(this)) return
        val d = display ?: return
        val bar = taskbarView
        try {
            val wm = createDisplayContext(d).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
                .getSystemService(WindowManager::class.java)
            (bar.parent as ViewGroup).removeView(bar)
            val host = Dock(wm)
            host.addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56), Gravity.BOTTOM))
            wm.addView(host, WindowManager.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(56), WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.BOTTOM })
            dock = host
        } catch (_: Exception) {
            // shortcut: without the overlay the taskbar stays inside the desktop, hidden behind full-screen apps.
            if (bar.parent == null) (window.decorView.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as FrameLayout)
                .addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56), Gravity.BOTTOM))
        }
    }

    /** The floating taskbar's window: full height on the desktop or under the mouse, a 6 dp strip over apps. */
    private inner class Dock(val wm: WindowManager) : FrameLayout(this@DesktopHomeActivity) {
        private var open = true

        fun expand(on: Boolean) {
            if (on == open || !isAttachedToWindow) return
            open = on
            val lp = layoutParams as WindowManager.LayoutParams
            lp.height = if (on) dp(56) else dp(6)
            setBackgroundColor(if (on) Color.TRANSPARENT else 0x99101318.toInt())
            getChildAt(0)?.visibility = if (on) View.VISIBLE else View.INVISIBLE
            wm.updateViewLayout(this, lp)
        }

        override fun dispatchHoverEvent(e: MotionEvent): Boolean {
            if (e.actionMasked == MotionEvent.ACTION_HOVER_EXIT) {
                main.postDelayed(collapse, 1200)
            } else {
                main.removeCallbacks(collapse)
                expand(true)
            }
            return super.dispatchHoverEvent(e)
        }

        override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
            if (!open && e.actionMasked == MotionEvent.ACTION_DOWN) {
                expand(true)
                return true
            }
            return super.onInterceptTouchEvent(e)
        }
    }

    // --- layout -----------------------------------------------------------------------------------------

    private fun buildDesktop(): View {
        val root = FrameLayout(this)
        root.background = wallpaper()
        root.addView(clock(), FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
            setMargins(dp(40), dp(36), 0, 0)
        })
        taskbarView = taskbar()
        root.addView(taskbarView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56), Gravity.BOTTOM))
        menu = startMenu()
        menu.visibility = View.GONE
        root.addView(menu, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        return root
    }

    /** The wallpaper Alero shows for this phone (one the owner picked), else the system's built-in one. */
    private fun wallpaper(): Drawable {
        val custom = File(filesDir, "wallpaper.jpg")
        if (custom.exists()) BitmapFactory.decodeFile(custom.path)?.let { return BitmapDrawable(resources, it) }
        try { WallpaperManager.getInstance(this).getBuiltInDrawable()?.let { return it } } catch (_: Exception) {}
        return GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(Color.rgb(32, 44, 72), Color.rgb(18, 20, 28)))
    }

    private fun clock(): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(TextClock(this@DesktopHomeActivity).apply {
            format12Hour = "h:mm"
            format24Hour = "HH:mm"
            textSize = 64f
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            setTextColor(Color.WHITE)
            setShadowLayer(12f, 0f, 2f, 0x66000000)
        })
        addView(TextClock(this@DesktopHomeActivity).apply {
            format12Hour = "EEEE, d 'de' MMMM"
            format24Hour = "EEEE, d 'de' MMMM"
            textSize = 18f
            setTextColor(Color.WHITE)
            setShadowLayer(8f, 0f, 1f, 0x66000000)
        })
    }

    private fun taskbar(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(16), 0)
            setBackgroundColor(0xE6101318.toInt())
        }
        bar.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_stat_alero)
            setColorFilter(Color.WHITE)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            background = round(0x33FFFFFF, 12)
            contentDescription = "Aplicaciones"
            tooltipText = "Aplicaciones"
            setOnClickListener { if (up) showMenu(menu.visibility != View.VISIBLE) else goHome(menu = true) }
        }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginEnd = dp(4) })
        bar.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_desk_home)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            contentDescription = "Inicio"
            tooltipText = "Inicio"
            setOnClickListener { goHome() }
        }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginEnd = dp(8) })
        taskbarApps = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        bar.addView(HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(taskbarApps)
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        battery = TextView(this).apply { setTextColor(Color.WHITE); textSize = 14f; setPadding(dp(12), 0, dp(12), 0) }
        bar.addView(battery)
        bar.addView(TextClock(this).apply { format12Hour = "h:mm a"; format24Hour = "HH:mm"; setTextColor(Color.WHITE); textSize = 15f })
        return bar
    }

    private fun startMenu(): FrameLayout {
        val dim = FrameLayout(this).apply {
            setBackgroundColor(0x55000000)
            setOnClickListener { showMenu(false) }
        }
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(16))
            background = round(0xF21A1D24.toInt(), 24)
            isClickable = true // taps inside do not close it
        }
        search = EditText(this).apply {
            hint = "Buscar aplicaciones"
            setHintTextColor(0x99FFFFFF.toInt())
            setTextColor(Color.WHITE)
            textSize = 16f
            isSingleLine = true
            background = round(0x22FFFFFF, 14)
            setPadding(dp(16), dp(12), dp(16), dp(12))
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) = adapter.filter(s?.toString().orEmpty())
            })
        }
        panel.addView(search)
        panel.addView(TextView(this).apply {
            text = "Mantén pulsada una app para fijarla en la barra"
            setTextColor(0x99FFFFFF.toInt())
            textSize = 12f
            setPadding(dp(4), dp(10), 0, dp(6))
        })
        panel.addView(GridView(this).apply {
            numColumns = GridView.AUTO_FIT
            columnWidth = dp(104)
            verticalSpacing = dp(6)
            stretchMode = GridView.STRETCH_COLUMN_WIDTH
            adapter = this@DesktopHomeActivity.adapter
            setOnItemClickListener { _, _, i, _ -> launch(this@DesktopHomeActivity.adapter.getItem(i)); showMenu(false) }
            setOnItemLongClickListener { _, _, i, _ -> togglePin(this@DesktopHomeActivity.adapter.getItem(i)); true }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        dim.addView(panel, FrameLayout.LayoutParams(dp(680), dp(560), Gravity.BOTTOM or Gravity.START).apply {
            setMargins(dp(12), dp(12), dp(12), dp(64))
        })
        return dim
    }

    private fun round(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }

    private fun showMenu(on: Boolean) {
        menu.visibility = if (on) View.VISIBLE else View.GONE
        val imm = getSystemService(InputMethodManager::class.java)
        if (on) {
            search.setText("")
            search.requestFocus()
        } else imm.hideSoftInputFromWindow(search.windowToken, 0)
    }

    // --- apps -------------------------------------------------------------------------------------------

    private fun label(app: ResolveInfo) = app.loadLabel(packageManager).toString()

    private fun loadApps() {
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        apps = packageManager.queryIntentActivities(query, 0)
            .filter { it.activityInfo.packageName != packageName }
            .distinctBy { it.activityInfo.packageName }
            .sortedBy { label(it).lowercase() }
        adapter.filter(if (::search.isInitialized) search.text.toString() else "")
        drawTaskbar()
    }

    private fun pins(): List<String> = prefs.getString("pins", null)?.split('\n')?.filter { it.isNotEmpty() }
        ?: listOf("com.android.chrome", "com.google.android.apps.photos", "com.google.android.apps.messaging", "com.google.android.youtube")

    private fun togglePin(app: ResolveInfo) {
        val pkg = app.activityInfo.packageName
        val now = pins().toMutableList()
        val added = if (now.remove(pkg)) false else { now += pkg; true }
        prefs.edit().putString("pins", now.joinToString("\n")).apply()
        Toast.makeText(this, if (added) "${label(app)} fijada en la barra" else "${label(app)} quitada de la barra", Toast.LENGTH_SHORT).show()
        drawTaskbar()
    }

    private fun drawTaskbar() {
        if (!::taskbarApps.isInitialized) return
        taskbarApps.removeAllViews()
        for (pkg in pins()) {
            val app = apps.firstOrNull { it.activityInfo.packageName == pkg } ?: continue
            taskbarApps.addView(ImageView(this).apply {
                setImageDrawable(app.loadIcon(packageManager))
                setPadding(dp(8), dp(8), dp(8), dp(8))
                contentDescription = label(app)
                tooltipText = label(app)
                setOnClickListener { launch(app) }
                setOnLongClickListener { togglePin(app); true }
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
        }
    }

    private fun updateBattery() {
        val level = getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val charging = getSystemService(BatteryManager::class.java).isCharging
        battery.text = if (level in 0..100) "${if (charging) "⚡ " else ""}$level %" else ""
    }

    private fun launch(app: ResolveInfo) {
        val displayId = currentDisplayId()
        if (displayId == Display.DEFAULT_DISPLAY) return
        val info = app.activityInfo
        try {
            val launch = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
                component = ComponentName(info.packageName, info.name)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
            }
            startActivity(launch, ActivityOptions.makeBasic().apply { launchDisplayId = displayId }.toBundle())
        } catch (_: Exception) {
            Toast.makeText(this, "Android no permite abrir ${label(app)} aquí.", Toast.LENGTH_LONG).show()
        }
    }

    private inner class AppsAdapter : BaseAdapter() {
        private var shown: List<ResolveInfo> = emptyList()

        fun filter(q: String) {
            val t = q.trim().lowercase()
            shown = if (t.isEmpty()) apps else apps.filter { label(it).lowercase().contains(t) || it.activityInfo.packageName.contains(t) }
            notifyDataSetChanged()
        }

        override fun getCount() = shown.size
        override fun getItem(i: Int) = shown[i]
        override fun getItemId(i: Int) = i.toLong()

        override fun getView(i: Int, convert: View?, parent: ViewGroup?): View {
            val cell = (convert as? LinearLayout) ?: LinearLayout(this@DesktopHomeActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(4), dp(8), dp(4), dp(8))
                addView(ImageView(context), LinearLayout.LayoutParams(dp(48), dp(48)))
                addView(TextView(context).apply {
                    setTextColor(Color.WHITE)
                    textSize = 12f
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    gravity = Gravity.CENTER
                    setPadding(0, dp(6), 0, 0)
                })
            }
            val app = shown[i]
            (cell.getChildAt(0) as ImageView).setImageDrawable(app.loadIcon(packageManager))
            (cell.getChildAt(1) as TextView).text = label(app)
            return cell
        }
    }
}
