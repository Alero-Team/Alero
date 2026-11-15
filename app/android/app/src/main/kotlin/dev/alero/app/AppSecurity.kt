package dev.alero.app

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.view.WindowManager
import io.flutter.plugin.common.MethodChannel

/** Authentication stays with Android: Alero never stores a PIN or fingerprint. */
class AppSecurity(private val activity: Activity) {
    private val prefs get() = activity.getSharedPreferences("security", Activity.MODE_PRIVATE)
    private var pending: MethodChannel.Result? = null
    private var change: Boolean? = null
    fun enabled() = prefs.getBoolean("locked", false)
    fun secureWindow() {
        if (enabled()) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    fun authenticate(result: MethodChannel.Result, setEnabled: Boolean? = null) {
        if (pending != null) return result.error("busy", Tr.t("Autenticación en curso", "Authentication in progress"), null)
        if (!activity.getSystemService(KeyguardManager::class.java).isDeviceSecure)
            return result.error("no_lock", Tr.t("Configura primero un PIN o huella en los ajustes de Android.", "Set up a PIN or fingerprint in Android settings first."), null)
        pending = result
        change = setEnabled
        if (Build.VERSION.SDK_INT >= 30) {
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle(Tr.t("Desbloquear Alero", "Unlock Alero"))
                .setSubtitle(Tr.t("Usa tu huella o el PIN del dispositivo", "Use your fingerprint or the device PIN"))
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                .build()
            prompt.authenticate(CancellationSignal(), activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) = finish(true)
                override fun onAuthenticationError(code: Int, message: CharSequence) = finish(false)
            })
        } else {
            @Suppress("DEPRECATION")
            val intent = activity.getSystemService(KeyguardManager::class.java)
                .createConfirmDeviceCredentialIntent(Tr.t("Desbloquear Alero", "Unlock Alero"), Tr.t("Confirma el PIN del dispositivo", "Confirm the device PIN"))
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST)
        }
    }
    fun finish(ok: Boolean) {
        if (ok) change?.let { prefs.edit().putBoolean("locked", it).apply() }
        secureWindow()
        change = null
        val result = pending
        pending = null
        result?.success(ok)
    }
    companion object { const val REQUEST = 45 }
}
