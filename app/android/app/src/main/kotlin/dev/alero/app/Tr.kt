package dev.alero.app

import android.content.Context
import java.util.Locale

/**
 * Wording for everything Android shows by itself (notifications, widgets, toasts), in Spanish or English.
 *
 * The app's language setting wins (the Flutter side sends it through `setLanguage`); with "system" it follows the
 * device, or Android's per-app language. Anything that is not Spanish reads English, as in the Flutter side.
 */
object Tr {
    private const val PREFS = "alero_language"
    private const val KEY = "lang"

    /** "es" or "en"; null follows the system language. */
    @Volatile private var forced: String? = null

    /** Reads the saved choice. Cheap: every entry point (activity, service, widget) calls it first. */
    fun load(c: Context) {
        forced = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null).clean()
    }

    /** Saves the app's choice: "system", "es" or "en". */
    fun save(c: Context, lang: String?) {
        forced = lang.clean()
        c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, forced).apply()
    }

    /** Sets the language without saving it (unit tests). */
    fun use(lang: String?) {
        forced = lang.clean()
    }

    fun spanish(): Boolean = (forced ?: Locale.getDefault().language) == "es"

    fun t(es: String, en: String): String = if (spanish()) es else en

    private fun String?.clean(): String? = if (this == "es" || this == "en") this else null
}
