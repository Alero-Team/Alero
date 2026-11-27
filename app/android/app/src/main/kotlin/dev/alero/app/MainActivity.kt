package dev.alero.app

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import androidx.core.content.ContextCompat
import android.widget.Toast
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Only what Flutter cannot do: content-URI descriptors, MediaStore, notifications and the foreground service.
 * The engine runs in Rust inside this process; nothing here decides protocol or trust.
 */
class MainActivity : FlutterActivity() {
    private val security by lazy { AppSecurity(this) }
    // Without it Android filters broadcasts, so the open app never heard the computer at its new address.
    private val multicast by lazy {
        (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager).createMulticastLock("alero:ui").apply { setReferenceCounted(false) }
    }
    private val fileLocations by lazy { getSharedPreferences("file_locations", MODE_PRIVATE) }
    private val sourceUris = java.util.concurrent.ConcurrentHashMap<Int, Uri>() // written off the main thread
    private var pickResult: MethodChannel.Result? = null
    private var scanResult: MethodChannel.Result? = null
    private var wallpaperResult: MethodChannel.Result? = null
    private var treeResult: MethodChannel.Result? = null
    private var mediaResult: MethodChannel.Result? = null
    private var pendingInstall: Intent? = null
    private var leftForInstall = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Tr.load(this)
        security.secureWindow()
        Notifier.init(this)
        // Copies left by a process killed mid-copy (a finished copy is unlinked at once); fresh ones may still be in use.
        File(cacheDir, "outgoing").listFiles()?.forEach { if (it.lastModified() < System.currentTimeMillis() - 600_000) it.delete() }
        Features.start(this)
        if (Prefs.background(this)) PbService.update(this, emptyList()) // no service unless asked or a computer is connected
        shared = intent
        shareReceived(intent)
        if (Build.VERSION.SDK_INT >= 31) splashScreen.setOnExitAnimationListener { it.remove() }
    }

    override fun onPause() {
        try { multicast.release() } catch (_: Exception) {}
        if (pendingInstall != null) leftForInstall = true
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        try { multicast.acquire() } catch (_: Exception) {}
        if (!leftForInstall) return
        leftForInstall = false
        val open = pendingInstall ?: return
        pendingInstall = null
        if (!packageManager.canRequestPackageInstalls()) {
            Toast.makeText(this, Tr.t("No se concedió permiso para instalar apps desde Alero.", "Permission to install apps from Alero was not granted."), Toast.LENGTH_LONG).show()
            return
        }
        try { startActivity(open) }
        catch (_: ActivityNotFoundException) { Toast.makeText(this, Tr.t("No hay un instalador de paquetes disponible.", "No package installer is available."), Toast.LENGTH_LONG).show() }
        catch (_: Exception) { Toast.makeText(this, Tr.t("El archivo ya no está disponible para el instalador.", "The file is no longer available to the installer."), Toast.LENGTH_LONG).show() }
    }

    /** Alero's own update: streams the verified APK into a PackageInstaller session; Android asks the user to confirm. */
    private fun installApk(path: String, result: MethodChannel.Result) {
        if (!packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            result.error("install_permission", Tr.t("Permite instalar apps desde Alero y vuelve a pulsar Actualizar.", "Allow installing apps from Alero, then tap Update again."), null)
            return
        }
        val action = "$packageName.UPDATE_STATUS"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    @Suppress("DEPRECATION")
                    val confirm = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else i.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    if (confirm != null) startActivity(confirm)
                    return
                }
                try { unregisterReceiver(this) } catch (_: Exception) {}
                if (status != PackageInstaller.STATUS_SUCCESS)
                    Toast.makeText(c, i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: Tr.t("No se pudo instalar la actualización.", "Couldn't install the update."), Toast.LENGTH_LONG).show()
            }
        }
        Thread {
            try {
                val installer = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    val file = File(path)
                    file.inputStream().use { input ->
                        session.openWrite("alero.apk", 0, file.length()).use { out ->
                            input.copyTo(out)
                            session.fsync(out)
                        }
                    }
                    // Commit before use{} closes the session (a closed session can't be committed).
                    ContextCompat.registerReceiver(this, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
                    val sent = PendingIntent.getBroadcast(this, id, Intent(action).setPackage(packageName), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                    session.commit(sent.intentSender)
                }
                runOnUiThread { result.success(null) }
            } catch (_: Exception) {
                try { unregisterReceiver(receiver) } catch (_: Exception) {}
                runOnUiThread { result.error("install_failed", Tr.t("No se pudo instalar la actualización.", "Couldn't install the update."), null) }
            }
        }.start()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        Files.trimMemory()
    }

    /** Answers Dart with `blocked`: something was denied and Android will not ask again (only system settings can grant it). */
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MEDIA && requestCode != SMS && requestCode != CALLS) return
        val r = mediaResult ?: return
        mediaResult = null
        val denied = permissions.filterIndexed { i, _ -> grantResults.getOrNull(i) != android.content.pm.PackageManager.PERMISSION_GRANTED }
        if (requestCode != MEDIA) Features.announce()
        // true: Android will not ask again, so the caller opens the app's permission page.
        r.success(denied.isNotEmpty() && (requestCode != MEDIA || Files.mediaState()["limited"] != true) && denied.none { shouldShowRequestPermissionRationale(it) })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shared = intent
        if (shareReceived(intent)) return
        channel?.invokeMethod("shared", null) // Dart asks for it with takeShared
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pb/android")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "vaultSeal", "vaultOpen" -> {
                    val bytes = call.arguments as? ByteArray
                    if (bytes == null) {
                        result.error("invalid_vault_data", Tr.t("Archivo inválido", "Invalid file"), null)
                    } else {
                        Thread {
                            try {
                                val encrypted = if (call.method == "vaultSeal") VaultCrypto.seal(bytes) else VaultCrypto.open(bytes)
                                runOnUiThread { result.success(encrypted) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("vault_crypto", Tr.t("No se pudo abrir o guardar el archivo cifrado.", "Couldn't open or save the encrypted file."), null) }
                            }
                        }.start()
                    }
                }
                "readVaultPicked" -> {
                    val descriptor = call.arguments as? Int
                    val uri = if (descriptor != null) sourceUris[descriptor] else null
                    if (uri == null) {
                        result.error("missing_vault_file", Tr.t("Selecciona un archivo primero.", "Select a file first."), null)
                    } else {
                        Thread {
                            try {
                                val maxBytes = 8 * 1024 * 1024
                                val data = java.io.ByteArrayOutputStream()
                                contentResolver.openInputStream(uri)!!.use { input ->
                                    val chunk = ByteArray(32768)
                                    while (true) {
                                        val n = input.read(chunk)
                                        if (n < 0) break
                                        if (n == 0) continue
                                        if (data.size() + n > maxBytes) error("Archivo supera 8 MB")
                                        data.write(chunk, 0, n)
                                    }
                                }
                                runOnUiThread { result.success(data.toByteArray()) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("vault_file", Tr.t("El archivo no se pudo leer (máximo 8 MB).", "The file couldn't be read (8 MB maximum)."), null) }
                            }
                        }.start()
                    }
                }
                "installPermission" -> result.success(packageManager.canRequestPackageInstalls())
                "requestInstallPermission" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "installApk" -> installApk(call.arguments as String, result)
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    result.success(null)
                }
                "lockEnabled" -> result.success(security.enabled())
                "authenticate" -> security.authenticate(result)
                "setLock" -> security.authenticate(result, call.arguments as Boolean)
                "allFiles" -> result.success(Files.allFiles())
                "requestAllFiles" -> {
                    if (Build.VERSION.SDK_INT >= 30) {
                        startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
                    } else {
                        requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), MEDIA)
                    }
                    result.success(null)
                }
                "rememberFile" -> {
                    val uri = sourceUris[call.argument<Int>("fd")]
                    if (uri != null) fileLocations.edit().putString("id:" + call.argument<String>("id"), uri.toString()).apply()
                    result.success(null)
                }
                "openFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    val id = call.argument<String>("id") ?: ""
                    Thread {
                        try {
                            val intent = fileIntent(path, id)
                            runOnUiThread {
                                try {
                                    if (intent.type == FileOpening.APK && !packageManager.canRequestPackageInstalls()) {
                                        pendingInstall = intent
                                        Toast.makeText(this, Tr.t("Permite instalar apps desde Alero. Al volver se abrirá el instalador.", "Allow installing apps from Alero. The installer will open when you come back."), Toast.LENGTH_LONG).show()
                                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                                    } else startActivity(intent)
                                    result.success(null)
                                } catch (_: ActivityNotFoundException) {
                                    pendingInstall = null
                                    result.error("no_handler", if (intent.type == FileOpening.APK) Tr.t("No hay un instalador de paquetes disponible.", "No package installer is available.") else Tr.t("No hay una app compatible para este tipo de archivo.", "No compatible app for this type of file."), null)
                                } catch (_: SecurityException) {
                                    pendingInstall = null
                                    result.error("open_permission", Tr.t("Android no permite abrir este archivo. Revisa los permisos de Alero.", "Android doesn't allow opening this file. Check Alero's permissions."), null)
                                } catch (_: Exception) {
                                    result.error("file_unavailable", Tr.t("El archivo ya no está disponible.", "The file is no longer available."), null)
                                }
                            }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("file_unavailable", Tr.t("El archivo no está disponible o no se puede leer.", "The file isn't available or can't be read."), null) }
                        }
                    }.start()
                }
                "setLanguage" -> {
                    Tr.save(this, call.arguments as? String)
                    result.success(null)
                }
                "deviceName" -> result.success(Build.MODEL ?: "Android")
                "pickFiles" -> pick(result)
                "closeFd" -> {
                    synchronized(open) { open.remove(call.arguments as Int) }?.close()
                    result.success(null)
                }
                "publish" -> {
                    val path = call.arguments as String
                    Thread { val where = publish(path); runOnUiThread { result.success(where) } }.start()
                }
                "background" -> result.success(Prefs.background(this))
                "setBackground" -> {
                    Prefs.setBackground(this, call.arguments as Boolean)
                    PbService.update(this, Features.onlineNames())
                    result.success(null)
                }
                "alert" -> {
                    Notifier.alert(call.argument<String>("title") ?: "", call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "notifAccess" -> result.success(NotifListener.enabled(this))
                "openNotifAccess" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                }
                "notifPermission" -> result.success(
                    Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED,
                )
                "openAppSettings" -> {
                    startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                    result.success(null)
                }
                "openDownloads" -> {
                    try {
                        startActivity(Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "openUrl" -> {
                    // https only: this opens a browser, never an app-specific scheme.
                    val url = call.arguments as? String
                    if (url != null && url.startsWith("https://")) {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)))
                        } catch (_: Exception) {}
                    }
                    result.success(null)
                }
                "openDevSettings" -> {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
                    result.success(null)
                }
                "files" -> result.success(
                    mapOf(
                        "allowed" to Prefs.files(this),
                        "permission" to Files.hasAnyMedia(),
                        "media" to Files.mediaState(),
                        "folders" to Files.treeNames(),
                    ),
                )
                "setFiles" -> {
                    val on = call.arguments as Boolean
                    Prefs.setFiles(this, on)
                    result.success(null)
                }
                "requestMedia" -> {
                    val missing = Files.missingPermissions()
                    if (missing.isEmpty()) return@setMethodCallHandler result.success(false)
                    mediaResult?.success(false)
                    mediaResult = result
                    requestPermissions(missing, MEDIA)
                }
                "openPermissions" -> {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", packageName, null)))
                    result.success(null)
                }
                "addFolder" -> {
                    treeResult?.success(false)
                    treeResult = result
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), TREE)
                }
                "sms" -> result.success(mapOf("allowed" to Prefs.sms(this), "permission" to Sms.readable()))
                "setSms" -> {
                    Prefs.setSms(this, call.arguments as Boolean)
                    Features.announce()
                    result.success(null)
                }
                "requestSms" -> {
                    val missing = Sms.permissions.filter { checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED }
                    if (missing.isEmpty()) return@setMethodCallHandler result.success(false)
                    mediaResult?.success(false)
                    mediaResult = result
                    requestPermissions(missing.toTypedArray(), SMS)
                }
                "calls" -> result.success(mapOf("allowed" to Prefs.calls(this), "permission" to Calls.granted()))
                "setCalls" -> {
                    Prefs.setCalls(this, call.arguments as Boolean)
                    Features.announce()
                    result.success(null)
                }
                "requestCalls" -> {
                    val missing = Calls.permissions.filter { checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED }
                    if (missing.isEmpty()) return@setMethodCallHandler result.success(false)
                    mediaResult?.success(false)
                    mediaResult = result
                    requestPermissions(missing.toTypedArray(), CALLS)
                }
                "mutedApps" -> result.success(NotifListener.mutedApps(this))
                "unmuteApp" -> {
                    Prefs.setMuted(this, call.arguments as String, false)
                    result.success(null)
                }
                "removeFolder" -> {
                    Files.removeTree(call.arguments as Int)
                    result.success(null)
                }
                "openUsbSettings" -> {
                    // No public API for the USB mode. The Pixel's USB screen is the nearest we can open; elsewhere
                    // the general settings, and the in-app guide explains the notification route.
                    val tries = listOf(
                        Intent().setClassName("com.android.settings", "com.android.settings.Settings\$UsbDetailsActivity"),
                        Intent(Settings.ACTION_DEVICE_INFO_SETTINGS),
                        Intent(Settings.ACTION_SETTINGS),
                    )
                    for (i in tries) {
                        try {
                            startActivity(i)
                            break
                        } catch (_: Exception) {}
                    }
                    result.success(null)
                }
                "deviceInfo" -> result.success(Features.info().toString())
                "scanQr" -> {
                    scanResult?.success(null)
                    scanResult = result
                    com.google.zxing.integration.android.IntentIntegrator(this)
                        .setPrompt(Tr.t("Escanea el código del ordenador", "Scan the computer's code"))
                        .setBeepEnabled(false)
                        .setCaptureActivity(PortraitCaptureActivity::class.java)
                        .setOrientationLocked(true)
                        .initiateScan(listOf(com.google.zxing.integration.android.IntentIntegrator.QR_CODE))
                }
                "takeShared" -> takeShared(result)
                "pickWallpaper" -> {
                    wallpaperResult?.success(false)
                    wallpaperResult = result
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("image/*"), WALLPAPER)
                }
                "clearWallpaper" -> result.success(Features.setWallpaper(null))
                else -> result.notImplemented()
            }
        }
    }

    /** What another app shared with us: files as open descriptors (like pickFiles) and/or text. */
    private fun takeShared(result: MethodChannel.Result) {
        val i = shared
        shared = null
        if (i == null) return result.success(null)
        i.getStringExtra(WIDGET)?.let { return result.success(mapOf("widget" to it)) }
        if (i.action != Intent.ACTION_SEND && i.action != Intent.ACTION_SEND_MULTIPLE) return result.success(null)
        val uris = mutableListOf<Uri>()
        if (i.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION") (i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris += it }
        } else {
            @Suppress("DEPRECATION") i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris += it }
        }
        // Providers may put some or all URIs in ClipData; do not send duplicates.
        i.clipData?.let { c -> for (k in 0 until c.itemCount) c.getItemAt(k).uri?.let { if (it !in uris) uris += it } }
        val text = i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: ""
        // Opening a descriptor can wait on the provider (cloud files): never on the main thread.
        Thread { val files = safeDescriptors(uris); runOnUiThread { result.success(mapOf("files" to files, "text" to text)) } }.start()
    }

    private fun pick(result: MethodChannel.Result) {
        pickResult?.success(emptyList<Any>())
        pickResult = result
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        startActivityForResult(i, PICK)
    }

    @Deprecated("FlutterActivity has no Activity Result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        com.google.zxing.integration.android.IntentIntegrator.parseActivityResult(requestCode, resultCode, data)?.let {
            scanResult?.success(it.contents)
            scanResult = null
            return
        }
        if (requestCode == AppSecurity.REQUEST) {
            security.finish(resultCode == Activity.RESULT_OK)
            return
        }
        if (requestCode == TREE) {
            val r = treeResult ?: return
            treeResult = null
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) return r.success(false)
            try {
                // Write lets the computer delete and rename inside the folder; a provider that refuses it stays read-only.
                try { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
                catch (_: SecurityException) { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                r.success(true)
            } catch (_: Exception) {
                r.success(false)
            }
            return
        }
        if (requestCode == WALLPAPER) {
            val r = wallpaperResult ?: return
            wallpaperResult = null
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) return r.success(false)
            Thread { val ok = Features.setWallpaper(uri); runOnUiThread { r.success(ok) } }.start()
            return
        }
        if (requestCode != PICK) return
        val r = pickResult ?: return
        pickResult = null
        val uris = mutableListOf<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            data.clipData?.let { c -> for (k in 0 until c.itemCount) uris += c.getItemAt(k).uri } ?: data.data?.let { uris += it }
        }
        Thread { val files = safeDescriptors(uris); runOnUiThread { r.success(files) } }.start()
    }

    // The descriptor stays open until Dart calls closeFd when the transfer ends: the engine reads from it.
    /** Another app's share must never point Alero at its own private files (keys, pairings) to send them out. */
    private fun ownData(uri: Uri): Boolean = when (uri.scheme) {
        "content" -> uri.authority?.startsWith(packageName) == true
        "file" -> try {
            val path = File(uri.path ?: "").canonicalPath
            listOfNotNull(applicationInfo.dataDir, applicationInfo.deviceProtectedDataDir, externalCacheDir?.parentFile?.path)
                .any { path == File(it).canonicalPath || path.startsWith(File(it).canonicalPath + File.separator) }
        } catch (_: Exception) { true }
        else -> true
    }

    private fun descriptors(uris: List<Uri>): List<Map<String, Any>> {
        var failed = 0
        val out = uris.mapNotNull { uri ->
            val pfd = try { if (ownData(uri)) null else openSource(uri) }
                catch (e: Exception) { android.util.Log.w("AleroShare", "opening shared file failed", e); null }
            if (pfd == null) { failed++; return@mapNotNull null }
            synchronized(open) { open[pfd.fd] = pfd }
            sourceUris[pfd.fd] = uri
            try { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            catch (_: Exception) { /* Shares may grant access only while the sender allows it. */ }
            mapOf("fd" to pfd.fd, "name" to displayName(uri))
        }
        if (failed > 0) runOnUiThread { Toast.makeText(this, Tr.t("No se pudo leer $failed archivo(s).", "Couldn't read $failed file(s)."), Toast.LENGTH_LONG).show() }
        return out
    }

    /**
     * A seekable descriptor holding exactly the file's bytes: the engine seeks it and trusts its size for the offer.
     * Pipes (Drive, cloud) and providers whose size differs from the real content (transcoded media) go through a cache copy.
     */
    private fun openSource(uri: Uri): ParcelFileDescriptor? {
        val direct = try { contentResolver.openFileDescriptor(uri, "r") } catch (e: Exception) { android.util.Log.w("AleroShare", "openFileDescriptor failed for $uri", e); null }
        val size = direct?.statSize ?: -1L // -1: not a regular file
        val declared = declaredSize(uri)
        if (direct != null && size >= 0 && (declared?.let { it < 0 || it == size } ?: (size > 0))) return direct
        // A pipe is read once: its open descriptor is the copy's input (reopening the URI would make the provider serve it twice).
        val pipe = direct != null && size < 0
        if (!pipe) direct?.close()
        val copy = copyToCache(uri, if (pipe) direct else null)
        // No copy (low storage): the direct descriptor's size is wrong or unknown, so the receiver would reject it.
        return copy
    }

    /** Dart awaits this answer: an unexpected provider error must not leave the pick or the share hanging. */
    private fun safeDescriptors(uris: List<Uri>): List<Map<String, Any>> =
        try { descriptors(uris) } catch (e: Exception) {
            android.util.Log.w("AleroShare", "reading shared files failed", e)
            runOnUiThread { Toast.makeText(this, Tr.t("No se pudieron leer los archivos.", "Couldn't read the files."), Toast.LENGTH_LONG).show() }
            emptyList()
        }

    private fun declaredSize(uri: Uri): Long? =
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
            }
        } catch (_: Exception) { null }

    /** Streams the URI into a cache file, opens it and unlinks it: the descriptor stays valid and nothing is left behind. */
    private fun copyToCache(uri: Uri, open: ParcelFileDescriptor? = null): ParcelFileDescriptor? {
        val f = try { File.createTempFile("send", null, File(cacheDir, "outgoing").apply { mkdirs() }) } catch (_: Exception) { return null }
        return try {
            val input = if (open != null) ParcelFileDescriptor.AutoCloseInputStream(open) else contentResolver.openInputStream(uri) ?: return null
            // Never fill the storage: past the free space (minus a margin) the copy is dropped and the usual error toast shows.
            val room = cacheDir.usableSpace - 64L * 1024 * 1024
            input.use { i ->
                f.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = i.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > room) throw java.io.IOException("not enough free space for the copy")
                        o.write(buf, 0, n)
                    }
                }
            }
            ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (e: Exception) {
            android.util.Log.w("AleroShare", "cache copy failed for $uri", e)
            null
        } finally { f.delete() }
    }

    /** Raw provider name; Dart makes it safe for the receiver (cleanName). */
    private fun displayName(uri: Uri): String =
        (try { contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null } } catch (_: Exception) { null })
            ?: uri.lastPathSegment ?: "archivo"

    /** Moves a received file from the app's private folder to Downloads/Alero. Returns where it went. */
    private fun publish(path: String): String {
        val src = File(path)
        if (Build.VERSION.SDK_INT < 29) return path // MediaStore.Downloads is API 29+
        // A file of a sent folder arrives under incoming/Folder/sub/: keep those folders in Downloads.
        val sub = path.substringAfter("/incoming/", "").substringBeforeLast('/', "")
        val rel = if (sub.isEmpty()) "Download/Alero" else "Download/Alero/$sub"
        return try {
            val cv = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, src.name)
                put(MediaStore.Downloads.MIME_TYPE, MimeTypeMap.getSingleton().getMimeTypeFromExtension(src.extension.lowercase()) ?: "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, rel)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv) ?: return path
            contentResolver.openOutputStream(uri)!!.use { out -> src.inputStream().use {
                require(it.copyTo(out) == src.length()) { "incomplete file" }
            } }
            cv.clear()
            cv.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, cv, null, null)
            fileLocations.edit().putString(path, uri.toString()).apply()
            src.delete()
            "Descargas/Alero/${if (sub.isEmpty()) "" else "$sub/"}${src.name}"
        } catch (e: Exception) {
            path // stays in the app's folder; Dart shows this path
        }
    }

    /** «Compartir» on a received file's notification: the system share sheet with that file. True if it was one. */
    private fun shareReceived(i: Intent): Boolean {
        val path = i.getStringExtra(SHARE_PATH) ?: return false
        val id = i.getStringExtra(SHARE_ID) ?: ""
        i.removeExtra(SHARE_PATH)
        Thread {
            try {
                val view = fileIntent(path, id)
                val send = Intent(Intent.ACTION_SEND).setType(view.type).putExtra(Intent.EXTRA_STREAM, view.data)
                    .apply { clipData = view.clipData }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                runOnUiThread { startActivity(Intent.createChooser(send, null)) }
            } catch (_: Exception) {
                runOnUiThread { Toast.makeText(this, Tr.t("El archivo ya no está disponible.", "The file is no longer available."), Toast.LENGTH_LONG).show() }
            }
        }.start()
        return true
    }

    private fun fileIntent(path: String, id: String): Intent {
        val saved = fileLocations.getString("id:$id", null) ?: fileLocations.getString(path, null)
        var uri = saved?.let(Uri::parse)
        // Older versions moved received files without remembering their content URI.
        if (uri == null && !File(path).isFile && Build.VERSION.SDK_INT >= 29) {
            contentResolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.RELATIVE_PATH} = ? AND ${MediaStore.Downloads.DISPLAY_NAME} = ?",
                arrayOf("Download/Alero/", File(path).name), "${MediaStore.Downloads.DATE_ADDED} DESC")?.use {
                if (it.moveToFirst()) uri = android.content.ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, it.getLong(0))
            }
        }
        if (uri == null) {
            val file = File(path)
            require(file.isFile && file.canRead()) { "missing file" }
            uri = try { androidx.core.content.FileProvider.getUriForFile(this, "$packageName.files", file) }
            catch (_: IllegalArgumentException) { Uri.fromFile(file) }
        }
        if (uri?.scheme == "file") {
            val source = File(uri!!.path!!)
            val folder = File(cacheDir, "opened-files").apply { mkdirs() }
            val cached = File(folder, source.path.hashCode().toUInt().toString(16) + "-" + source.name)
            if (!cached.exists() || cached.length() != source.length() || cached.lastModified() != source.lastModified()) {
                val temporary = File.createTempFile("open-", ".part", folder)
                try {
                    source.copyTo(temporary, overwrite = true)
                    require(temporary.length() == source.length()) { "incomplete file" }
                    require(temporary.renameTo(cached)) { "cache publish failed" }
                    cached.setLastModified(source.lastModified())
                } finally { temporary.delete() }
            }
            uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.files", cached)
        }
        contentResolver.openAssetFileDescriptor(uri!!, "r")?.use {
            require(it.length != 0L) { "empty file" }
        } ?: error("unreadable file")
        val name = displayName(uri!!)
        val mime = FileOpening.mime(if (File(path).extension.equals("apk", true)) path else name,
            contentResolver.getType(uri!!), MimeTypeMap.getSingleton().getMimeTypeFromExtension(File(name).extension.lowercase()))
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            .apply { clipData = ClipData.newRawUri("archivo", uri) }
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    companion object {
        /** Intent extra set by the home-screen widgets: what to open (see Hub.widgetAction). */
        const val WIDGET = "alero.widget"
        /** Set by the received-file notification's «Compartir». */
        const val SHARE_PATH = "alero.share.path"
        const val SHARE_ID = "alero.share.id"
        private var channel: MethodChannel? = null
        private var shared: Intent? = null
        private const val PICK = 41
        private const val WALLPAPER = 42
        private const val TREE = 43
        private const val MEDIA = 44
        private const val SMS = 45
        private const val CALLS = 46
        private val open = HashMap<Int, ParcelFileDescriptor>()
    }
}
