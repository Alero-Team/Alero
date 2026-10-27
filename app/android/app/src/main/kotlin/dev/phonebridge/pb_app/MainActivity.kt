package dev.phonebridge.pb_app

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
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
    private var pickResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notifier.init(this)
        startForegroundService(Intent(this, PbService::class.java))
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pb/android").setMethodCallHandler { call, result ->
            when (call.method) {
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
                "status" -> {
                    PbService.status(this, call.arguments as String)
                    result.success(null)
                }
                "alert" -> {
                    Notifier.alert(call.argument<String>("title") ?: "", call.argument<String>("text") ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
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
        if (requestCode != PICK) return
        val r = pickResult ?: return
        pickResult = null
        val uris = mutableListOf<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            data.clipData?.let { c -> for (k in 0 until c.itemCount) uris += c.getItemAt(k).uri } ?: data.data?.let { uris += it }
        }
        // The descriptor stays open until Dart calls closeFd when the transfer ends: the engine reads from it.
        r.success(uris.mapNotNull { uri ->
            val pfd = try { contentResolver.openFileDescriptor(uri, "r") } catch (_: Exception) { null } ?: return@mapNotNull null
            synchronized(open) { open[pfd.fd] = pfd }
            mapOf("fd" to pfd.fd, "name" to safeName(displayName(uri)))
        })
    }

    private fun displayName(uri: Uri): String =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: uri.lastPathSegment ?: "archivo"

    /** Windows-hostile characters are replaced; the core would reject them otherwise. */
    private fun safeName(n: String) =
        n.map { if (it.isISOControl() || it in "/\\:*?\"<>|") '_' else it }.joinToString("").trim().trimEnd('.').ifEmpty { "archivo" }

    /** Moves a received file from the app's private folder to Downloads/Phonebridge. Returns where it went. */
    private fun publish(path: String): String {
        val src = File(path)
        if (Build.VERSION.SDK_INT < 29) return path // MediaStore.Downloads is API 29+
        return try {
            val cv = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, src.name)
                put(MediaStore.Downloads.MIME_TYPE, MimeTypeMap.getSingleton().getMimeTypeFromExtension(src.extension.lowercase()) ?: "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/Phonebridge")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv) ?: return path
            contentResolver.openOutputStream(uri)!!.use { out -> src.inputStream().use { it.copyTo(out) } }
            cv.clear()
            cv.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, cv, null, null)
            src.delete()
            "Descargas/Phonebridge/${src.name}"
        } catch (e: Exception) {
            path // stays in the app's folder; Dart shows this path
        }
    }

    companion object {
        private const val PICK = 41
        private val open = HashMap<Int, ParcelFileDescriptor>()
    }
}
