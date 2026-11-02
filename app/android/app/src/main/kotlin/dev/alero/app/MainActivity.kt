package dev.alero.app

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
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
    private val sourceUris = HashMap<Int, Uri>()
    private var pickResult: MethodChannel.Result? = null
    private var scanResult: MethodChannel.Result? = null
    private var wallpaperResult: MethodChannel.Result? = null
    private var treeResult: MethodChannel.Result? = null
    private var mediaResult: MethodChannel.Result? = null
    private var pendingInstall: Intent? = null
    private var leftForInstall = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        security.secureWindow()
        Notifier.init(this)
        Features.start(this)
        if (Prefs.background(this)) PbService.update(this, emptyList()) // no service unless asked or a computer is connected
        shared = intent
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
            Toast.makeText(this, "No se concedió permiso para instalar apps desde Alero.", Toast.LENGTH_LONG).show()
            return
        }
        try { startActivity(open) }
        catch (_: ActivityNotFoundException) { Toast.makeText(this, "No hay un instalador de paquetes disponible.", Toast.LENGTH_LONG).show() }
        catch (_: Exception) { Toast.makeText(this, "El archivo ya no está disponible para el instalador.", Toast.LENGTH_LONG).show() }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        Files.trimMemory()
    }

    /** Answers Dart with `blocked`: something was denied and Android will not ask again (only system settings can grant it). */
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MEDIA) return
        val r = mediaResult ?: return
        mediaResult = null
        val denied = permissions.filterIndexed { i, _ -> grantResults.getOrNull(i) != android.content.pm.PackageManager.PERMISSION_GRANTED }
        r.success(denied.isNotEmpty() && Files.mediaState()["limited"] != true && denied.none { shouldShowRequestPermissionRationale(it) })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shared = intent
        channel?.invokeMethod("shared", null) // Dart asks for it with takeShared
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pb/android")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "firstLaunch" -> {
                    val prefs = getSharedPreferences("startup", MODE_PRIVATE)
                    val first = !prefs.getBoolean("introSeen", false)
                    prefs.edit().putBoolean("introSeen", true).apply()
                    result.success(first)
                }
                "installPermission" -> result.success(packageManager.canRequestPackageInstalls())
                "requestInstallPermission" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    result.success(null)
                }
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
                                        Toast.makeText(this, "Permite instalar apps desde Alero. Al volver se abrirá el instalador.", Toast.LENGTH_LONG).show()
                                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                                    } else startActivity(intent)
                                    result.success(null)
                                } catch (_: ActivityNotFoundException) {
                                    pendingInstall = null
                                    result.error("no_handler", if (intent.type == FileOpening.APK) "No hay un instalador de paquetes disponible." else "No hay una app compatible para este tipo de archivo.", null)
                                } catch (_: SecurityException) {
                                    pendingInstall = null
                                    result.error("open_permission", "Android no permite abrir este archivo. Revisa los permisos de Alero.", null)
                                } catch (_: Exception) {
                                    result.error("file_unavailable", "El archivo ya no está disponible.", null)
                                }
                            }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("file_unavailable", "El archivo no está disponible o no se puede leer.", null) }
                        }
                    }.start()
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
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), TREE)
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
                        .setPrompt("Escanea el código del ordenador")
                        .setBeepEnabled(false)
                        .setCaptureActivity(PortraitCaptureActivity::class.java)
                        .setOrientationLocked(true)
                        .initiateScan(listOf(com.google.zxing.integration.android.IntentIntegrator.QR_CODE))
                }
                "takeShared" -> result.success(takeShared())
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
    private fun takeShared(): Map<String, Any>? {
        val i = shared ?: return null
        shared = null
        i.getStringExtra(WIDGET)?.let { return mapOf("widget" to it) }
        if (i.action != Intent.ACTION_SEND && i.action != Intent.ACTION_SEND_MULTIPLE) return null
        val uris = mutableListOf<Uri>()
        if (i.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION") (i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris += it }
        } else {
            @Suppress("DEPRECATION") i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris += it }
        }
        return mapOf("files" to descriptors(uris), "text" to (i.getStringExtra(Intent.EXTRA_TEXT) ?: ""))
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
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
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
        r.success(descriptors(uris))
    }

    // The descriptor stays open until Dart calls closeFd when the transfer ends: the engine reads from it.
    private fun descriptors(uris: List<Uri>) =
        uris.mapNotNull { uri ->
            val pfd = try { contentResolver.openFileDescriptor(uri, "r") } catch (_: Exception) { null } ?: return@mapNotNull null
            synchronized(open) { open[pfd.fd] = pfd }
            sourceUris[pfd.fd] = uri
            try { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            catch (_: SecurityException) { /* Shares may grant access only while the sender allows it. */ }
            mapOf("fd" to pfd.fd, "name" to safeName(displayName(uri)))
        }

    private fun displayName(uri: Uri): String =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: uri.lastPathSegment ?: "archivo"

    /** Windows-hostile characters are replaced; the core would reject them otherwise. */
    private fun safeName(n: String) =
        n.map { if (it.isISOControl() || it in "/\\:*?\"<>|") '_' else it }.joinToString("").trim().trimEnd('.').ifEmpty { "archivo" }

    /** Moves a received file from the app's private folder to Downloads/Alero. Returns where it went. */
    private fun publish(path: String): String {
        val src = File(path)
        if (Build.VERSION.SDK_INT < 29) return path // MediaStore.Downloads is API 29+
        return try {
            val cv = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, src.name)
                put(MediaStore.Downloads.MIME_TYPE, MimeTypeMap.getSingleton().getMimeTypeFromExtension(src.extension.lowercase()) ?: "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/Alero")
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
            "Descargas/Alero/${src.name}"
        } catch (e: Exception) {
            path // stays in the app's folder; Dart shows this path
        }
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
        private var channel: MethodChannel? = null
        private var shared: Intent? = null
        private const val PICK = 41
        private const val WALLPAPER = 42
        private const val TREE = 43
        private const val MEDIA = 44
        private val open = HashMap<Int, ParcelFileDescriptor>()
    }
}
