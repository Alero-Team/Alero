package dev.alero.app

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The phone's files for a paired computer (`pb.x.fs.*`). Only what Android lets an ordinary app see:
 *  - photos, videos and music through MediaStore (needs the "Photos and videos" / "Music and audio" permission);
 *  - the files Alero itself received (Download/Alero), no permission;
 *  - folders the user picked with the system folder picker (a persisted grant for that folder only).
 * Private app folders and other apps' data are out of reach by design, and nothing here requests broad storage
 * access. Off until the user turns it on in Settings; the computer's requests are refused otherwise.
 */
object Files {
    private lateinit var ctx: Context
    private val pool = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private val sending = ConcurrentHashMap<String, ParcelFileDescriptor>() // transfer id -> descriptor to close
    private val cache = object : LinkedHashMap<String, List<JSONObject>>(8, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, List<JSONObject>>) = size > 6
    }
    private val watchers = ConcurrentHashMap<String, Long>() // peers that listed recently: told when things change
    private var observer: ContentObserver? = null
    private var asked = 0L
    private const val PAGE = 300

    fun init(c: Context) {
        ctx = c.applicationContext
    }

    fun allowed() = Prefs.files(ctx)
    fun allFiles() = if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else has(Manifest.permission.READ_EXTERNAL_STORAGE)

    private fun storageFile(path: String): java.io.File {
        if (!allFiles()) throw SecurityException("storage permission")
        return StoragePaths.resolve(Environment.getExternalStorageDirectory(), path)
    }

    private fun listStorage(path: String): List<JSONObject> {
        val base = Environment.getExternalStorageDirectory().canonicalFile
        val folder = storageFile(path)
        val children = folder.listFiles() ?: throw SecurityException("unreadable folder")
        return children.mapNotNull { file ->
            val relative = file.relativeTo(base).invariantSeparatorsPath
            try {
                val safe = storageFile(relative)
                entry(safe.name, safe.isDirectory, if (safe.isDirectory) StoragePaths.count(safe) else safe.length(),
                    safe.lastModified() / 1000,
                    android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(safe.extension.lowercase()) ?: "",
                    relative, if (safe.isDirectory) relative else "")
            } catch (_: SecurityException) { null }
        }.sortedWith(compareBy({ !it.getBoolean("dir") }, { it.getString("name").lowercase() }))
    }

    // --- permissions ------------------------------------------------------------------------------------

    fun mediaPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 33) {
            // Android 14+ lets the user share only some photos ("limited access"); declaring it makes that choice work.
            val p = arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_AUDIO)
            if (Build.VERSION.SDK_INT >= 34) p + Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED else p
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    /** Which libraries are fully readable; `limited` = Android 14+ "selected photos only" (partial, not full access). */
    fun mediaState(): Map<String, Boolean> {
        val full = Build.VERSION.SDK_INT < 33
        fun f(p: String) = if (full) has(Manifest.permission.READ_EXTERNAL_STORAGE) else has(p)
        val images = f(Manifest.permission.READ_MEDIA_IMAGES)
        val video = f(Manifest.permission.READ_MEDIA_VIDEO)
        return mapOf(
            "images" to images,
            "video" to video,
            "audio" to f(Manifest.permission.READ_MEDIA_AUDIO),
            "limited" to (Build.VERSION.SDK_INT >= 34 && !images && !video && has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)),
        )
    }

    /** What to ask the system for: only what is not granted yet. */
    fun missingPermissions(): Array<String> = mediaPermissions().filter { !has(it) }.let { m ->
        // READ_MEDIA_VISUAL_USER_SELECTED alone is not a request; it only travels with photos/videos.
        if (m.any { it != Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED }) m.toTypedArray() else emptyArray()
    }

    private fun has(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** At least one library can be read (the user may have granted only photos, or only music). */
    fun hasAnyMedia() = listOf("images", "video", "audio").any { hasMedia(it) }

    private fun hasMedia(root: String): Boolean = when {
        Build.VERSION.SDK_INT < 33 -> has(Manifest.permission.READ_EXTERNAL_STORAGE)
        root == "images" -> has(Manifest.permission.READ_MEDIA_IMAGES) || (Build.VERSION.SDK_INT >= 34 && has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        root == "video" -> has(Manifest.permission.READ_MEDIA_VIDEO) || (Build.VERSION.SDK_INT >= 34 && has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        else -> has(Manifest.permission.READ_MEDIA_AUDIO)
    }

    // --- granted folders --------------------------------------------------------------------------------

    private fun trees(): List<Uri> =
        ctx.contentResolver.persistedUriPermissions.filter { it.isReadPermission && DocumentsContract.isTreeUri(it.uri) }.map { it.uri }.sortedBy { it.toString() }

    fun treeNames(): List<String> = trees().map { treeName(it) }

    private fun treeName(t: Uri): String = try {
        ctx.contentResolver.query(
            DocumentsContract.buildDocumentUriUsingTree(t, DocumentsContract.getTreeDocumentId(t)),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Carpeta"
    } catch (_: Exception) {
        "Carpeta"
    }

    fun removeTree(i: Int) {
        val t = trees().getOrNull(i) ?: return
        try {
            ctx.contentResolver.releasePersistableUriPermission(t, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                if (ctx.contentResolver.persistedUriPermissions.any { it.uri == t && it.isWritePermission }) android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        } catch (_: Exception) {}
    }

    // --- messages ---------------------------------------------------------------------------------------

    fun handle(peer: String, kind: String, body: JSONObject) {
        if (!allowed()) {
            Bridge.sendTo(peer, "pb.x.fs.denied", JSONObject().put("reason", "not_allowed"))
            askOwner()
            return
        }
        watchers[peer] = System.currentTimeMillis()
        watch()
        pool.execute {
            try {
                when (kind) {
                    "pb.x.fs.roots.request" -> Bridge.sendTo(peer, "pb.x.fs.roots", roots())
                    "pb.x.fs.list" -> list(peer, body)
                    "pb.x.fs.thumb" -> thumb(peer, body)
                    "pb.x.fs.get" -> get(peer, body)
                    "pb.x.fs.getdir" -> getDir(peer, body)
                    "pb.x.fs.delete" -> change(peer, body, "delete")
                    "pb.x.fs.rename" -> change(peer, body, "rename")
                }
            } catch (e: SecurityException) {
                Bridge.sendTo(peer, "pb.x.fs.denied", JSONObject().put("reason", "no_permission"))
            } catch (_: Exception) {
                // a bad request from a paired device must not stop the service
            }
        }
    }

    /** The computer asked while the switch is off: a notification (at most one every 5 minutes) lets the owner decide. */
    private fun askOwner() {
        val now = System.currentTimeMillis()
        if (now - asked < 300_000) return
        asked = now
        Notifier.alert("Archivos del teléfono", "Un ordenador quiere ver tus archivos. Toca para decidirlo en Ajustes.")
    }

    private fun roots(): JSONObject {
        val a = JSONArray()
        fun add(id: String, name: String, kind: String, ok: Boolean) = a.put(JSONObject().put("id", id).put("name", name).put("kind", kind).put("ok", ok))
        add("images", "Fotos", "images", hasMedia("images"))
        add("video", "Vídeos", "video", hasMedia("video"))
        add("audio", "Música", "audio", hasMedia("audio"))
        if (Build.VERSION.SDK_INT >= 29) add("alero", "Recibidos de Alero", "alero", true)
        add("storage", "Todas las carpetas", "storage", allFiles())
        trees().forEachIndexed { i, t -> add("tree:$i", treeName(t), "tree", true) }
        return JSONObject().put("allowed", true).put("roots", a)
    }

    private fun mediaUri(root: String): Uri = when (root) {
        "images" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
    }

    private fun uriFor(root: String, id: String): Uri? = when {
        root == "storage" -> Uri.fromFile(storageFile(id).also { if (!it.isFile) throw SecurityException("not a file") })
        root == "alero" -> if (Build.VERSION.SDK_INT >= 29) ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id.toLong()) else null
        root.startsWith("tree:") -> trees().getOrNull(root.substring(5).toIntOrNull() ?: -1)?.let { DocumentsContract.buildDocumentUriUsingTree(it, id) }
        // "t<tree>|<document id>": a photo/video found inside a folder the user added (see listMediaFlat)
        root in setOf("images", "video") && id.startsWith("t") && id.contains('|') ->
            trees().getOrNull(id.substring(1, id.indexOf('|')).toIntOrNull() ?: -1)?.let { DocumentsContract.buildDocumentUriUsingTree(it, id.substring(id.indexOf('|') + 1)) }
        root in setOf("images", "video", "audio") -> ContentUris.withAppendedId(mediaUri(root), id.toLong())
        else -> null
    }

    private fun entry(name: String, dir: Boolean, size: Long, mtime: Long, mime: String, id: String, path: String = "") =
        JSONObject().put("name", name).put("dir", dir).put("size", size).put("mtime", mtime).put("mime", mime).put("id", id).put("path", path)

    private fun like(s: String) = s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    /** One folder level of a media library, built from the files' paths (MediaStore has no folder objects). */
    private fun listMedia(root: String, path: String): List<JSONObject> {
        if (!hasMedia(root)) throw SecurityException("media permission")
        val base = Environment.getExternalStorageDirectory().path + "/"
        val prefix = base + (if (path.isEmpty()) "" else "$path/")
        val folders = LinkedHashMap<String, LongArray>() // name -> [items, newest]
        val files = ArrayList<JSONObject>()
        @Suppress("DEPRECATION") val data = MediaStore.MediaColumns.DATA
        ctx.contentResolver.query(
            mediaUri(root),
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.MIME_TYPE, data),
            "$data LIKE ? ESCAPE '\\'" + if (root == "audio") " AND ${MediaStore.Audio.Media.DURATION} > 5000 AND ${MediaStore.Audio.Media.IS_RINGTONE} = 0 AND ${MediaStore.Audio.Media.IS_NOTIFICATION} = 0 AND ${MediaStore.Audio.Media.IS_ALARM} = 0" else "",
            arrayOf(like(prefix) + "%"), null,
        )?.use { c ->
            while (c.moveToNext()) {
                val full = c.getString(5) ?: continue
                if (!full.startsWith(prefix)) continue
                val rel = full.substring(prefix.length)
                val slash = rel.indexOf('/')
                if (slash >= 0) {
                    val f = folders.getOrPut(rel.substring(0, slash)) { longArrayOf(0, 0) }
                    f[0]++
                    f[1] = maxOf(f[1], c.getLong(3))
                } else {
                    files += entry(c.getString(1) ?: rel, false, c.getLong(2), c.getLong(3), c.getString(4) ?: "", c.getLong(0).toString())
                }
            }
        }
        val dirs = folders.entries.sortedBy { it.key.lowercase() }
            .map { (n, f) -> entry(n, true, f[0], f[1], "", "", if (path.isEmpty()) n else "$path/$n") }
        return dirs + files.sortedBy { it.getString("name").lowercase() }
    }

    /**
     * Photos or videos from every readable place, as one flat list: the whole MediaStore library (by media type,
     * not by folder) plus whatever the granted folders hold with an `image/` or `video/` MIME type. A file seen
     * through both sources is listed once (same real path).
     */
    private fun listMediaFlat(root: String): List<JSONObject> {
        if (!hasMedia(root)) throw SecurityException("media permission")
        val prefix = if (root == "images") "image/" else "video/"
        val base = Environment.getExternalStorageDirectory().path
        val seen = HashSet<String>()
        val out = ArrayList<JSONObject>()
        @Suppress("DEPRECATION") val data = MediaStore.MediaColumns.DATA
        ctx.contentResolver.query(
            mediaUri(root),
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.MIME_TYPE, data),
            null, null, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val mime = c.getString(4) ?: ""
                if (mime.isNotEmpty() && !mime.startsWith(prefix)) continue
                val path = c.getString(5)
                if (path != null && !seen.add(path)) continue
                out += entry(c.getString(1) ?: "?", false, c.getLong(2), c.getLong(3), mime, c.getLong(0).toString())
            }
        }
        trees().forEachIndexed { i, tree ->
            var budget = 20_000 // documents visited per folder: a deliberate cap so a huge tree cannot stall the phone
            fun walk(doc: String, depth: Int) {
                if (depth > 12 || budget <= 0) return
                val dirs = ArrayList<String>()
                ctx.contentResolver.query(
                    DocumentsContract.buildChildDocumentsUriUsingTree(tree, doc),
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE,
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_MIME_TYPE,
                    ),
                    null, null, null,
                )?.use { c ->
                    while (c.moveToNext() && budget-- > 0) {
                        val id = c.getString(0)
                        val mime = c.getString(4) ?: ""
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            dirs += id
                        } else if (mime.startsWith(prefix)) {
                            // "primary:DCIM/a.jpg" is /storage/emulated/0/DCIM/a.jpg: the same file MediaStore listed
                            val real = if (id.startsWith("primary:")) "$base/${id.substring(8)}" else null
                            if (real != null && !seen.add(real)) continue
                            out += entry(c.getString(1) ?: "?", false, if (c.isNull(2)) 0 else c.getLong(2), c.getLong(3) / 1000, mime, "t$i|$id")
                        }
                    }
                }
                dirs.forEach { walk(it, depth + 1) }
            }
            try { walk(DocumentsContract.getTreeDocumentId(tree), 0) } catch (_: Exception) {}
        }
        return out.sortedByDescending { it.getLong("mtime") }
    }

    private fun listAlero(): List<JSONObject> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val out = ArrayList<JSONObject>()
        ctx.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.MIME_TYPE),
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ?", arrayOf("Download/Alero/"), "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) out += entry(c.getString(1) ?: "archivo", false, c.getLong(2), c.getLong(3), c.getString(4) ?: "", c.getLong(0).toString())
        }
        return out
    }

    private fun treeCount(tree: Uri, doc: String): Long = try {
        ctx.contentResolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, doc),
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { c ->
            var count = 0L
            while (count < 1000 && c.moveToNext()) count++
            count
        } ?: -1L
    } catch (_: Exception) { -1L }

    fun trimMemory() { synchronized(cache) { cache.clear() } }

    private fun listTree(root: String, path: String): List<JSONObject> {
        val tree = trees().getOrNull(root.substring(5).toIntOrNull() ?: -1) ?: return emptyList()
        val doc = path.ifEmpty { DocumentsContract.getTreeDocumentId(tree) }
        val out = ArrayList<JSONObject>()
        ctx.contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(tree, doc),
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val mime = c.getString(4) ?: ""
                val dir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                out += entry(c.getString(1) ?: "?", dir, if (dir) treeCount(tree, c.getString(0)) else if (c.isNull(2)) 0 else c.getLong(2), c.getLong(3) / 1000, mime, c.getString(0), if (dir) c.getString(0) else "")
            }
        }
        return out.sortedWith(compareBy({ !it.getBoolean("dir") }, { it.getString("name").lowercase() }))
    }

    private fun list(peer: String, b: JSONObject) {
        val root = b.optString("root")
        val path = b.optString("path")
        val offset = b.optInt("offset", 0).coerceAtLeast(0)
        val key = "$root|$path"
        val all = synchronized(cache) { if (offset == 0) null else cache[key] } ?: when {
            root == "storage" -> listStorage(path)
            root == "alero" -> listAlero()
            root.startsWith("tree:") -> listTree(root, path)
            root == "images" || root == "video" -> listMediaFlat(root)
            root == "audio" -> listMedia(root, path)
            else -> emptyList()
        }.also { synchronized(cache) { if (it.size > PAGE) cache[key] = it } }
        val a = JSONArray()
        for (i in offset until minOf(all.size, offset + PAGE)) a.put(all[i])
        if (offset.toLong() + PAGE >= all.size) synchronized(cache) { cache.remove(key) }
        Bridge.sendTo(
            peer, "pb.x.fs.entries",
            JSONObject().put("root", root).put("path", path).put("offset", offset).put("total", all.size).put("entries", a),
        )
    }

    private fun thumb(peer: String, b: JSONObject) {
        if (Build.VERSION.SDK_INT < 29) return
        val root = b.optString("root")
        val id = b.optString("id")
        val uri = uriFor(root, id) ?: return
        val bmp = try { ctx.contentResolver.loadThumbnail(uri, Size(192, 192), null) } catch (_: Exception) { return }
        val out = ByteArrayOutputStream()
        try { bmp.compress(Bitmap.CompressFormat.JPEG, 72, out) } finally { bmp.recycle() }
        Bridge.sendTo(peer, "pb.x.fs.thumb.data", JSONObject().put("root", root).put("id", id).put("jpeg", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)))
    }

    /** Sends the file to the computer as an ordinary transfer (resumable, with progress on both sides). */
    private fun clean(n: String) =
        n.map { if (it.isISOControl() || it in "/\\:*?\"<>|") '_' else it }.joinToString("").trim().trimEnd('.').ifEmpty { "archivo" }

    private fun get(peer: String, b: JSONObject) {
        val uri = uriFor(b.optString("root"), b.optString("id")) ?: return
        sendUri(peer, uri, clean(b.optString("name")))
    }

    /** Sends one file as an ordinary transfer; false (and the computer is told) when the engine refused it. */
    private fun sendUri(peer: String, uri: Uri, name: String): Boolean {
        val pfd = ctx.contentResolver.openFileDescriptor(uri, "r") ?: return false
        val r = Bridge.sendFile(peer, "fd:${pfd.fd}", name)
        if (r.startsWith("!") || r.isEmpty()) {
            pfd.close()
            Bridge.sendTo(peer, "pb.x.fs.denied", JSONObject().put("reason", "send_failed").put("detail", r.removePrefix("!")))
            return false
        }
        sending[r] = pfd
        ctx.getSharedPreferences("file_locations", Context.MODE_PRIVATE).edit().putString("id:$r", uri.toString()).apply()
        return true
    }

    /**
     * Sends every file of a folder, named `Folder/sub/file` so the computer rebuilds it. Shared storage (and music
     * folders, which are storage paths) or a folder the owner added; at most 5000 files and 16 levels.
     */
    private fun getDir(peer: String, b: JSONObject) {
        val root = b.optString("root")
        val path = b.optString("path")
        if (path.isEmpty()) return
        val top = clean(b.optString("name"))
        val files = ArrayList<Pair<Uri, String>>()
        if (root == "storage" || root == "audio") {
            val dir = storageFile(path)
            dir.walkTopDown().maxDepth(15).filter { it.isFile }.take(5000).forEach { f ->
                // Every step must stay inside shared storage (no links out, no private folders).
                val safe = try { storageFile(f.relativeTo(Environment.getExternalStorageDirectory().canonicalFile).invariantSeparatorsPath) } catch (_: SecurityException) { return@forEach }
                files += Uri.fromFile(safe) to "$top/" + f.relativeTo(dir).invariantSeparatorsPath.split('/').joinToString("/") { clean(it) }
            }
        } else if (root.startsWith("tree:")) {
            val tree = trees().getOrNull(root.substring(5).toIntOrNull() ?: -1) ?: return
            fun walk(doc: String, rel: String, depth: Int) {
                if (depth > 15 || files.size >= 5000) return
                ctx.contentResolver.query(
                    DocumentsContract.buildChildDocumentsUriUsingTree(tree, doc),
                    arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE),
                    null, null, null,
                )?.use { c ->
                    while (c.moveToNext() && files.size < 5000) {
                        val name = "$rel/${clean(c.getString(1) ?: "archivo")}"
                        if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) walk(c.getString(0), name, depth + 1)
                        else files += DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0)) to name
                    }
                }
            }
            walk(path, top, 0)
        } else return
        Bridge.sendTo(peer, "pb.x.fs.dir", JSONObject().put("name", top).put("files", files.size))
        for ((uri, name) in files) if (!sendUri(peer, uri, name)) return
    }

    // --- delete and rename -------------------------------------------------------------------------------

    /** The real thing an entry names: a File in shared storage (music folders are storage paths too), else a Uri. */
    private fun target(b: JSONObject): Any? {
        val root = b.optString("root")
        if (b.optBoolean("dir")) {
            val path = b.optString("path")
            return when {
                path.isEmpty() -> null // never a whole location
                root == "storage" || root == "audio" -> storageFile(path)
                root.startsWith("tree:") -> trees().getOrNull(root.substring(5).toIntOrNull() ?: -1)?.let { DocumentsContract.buildDocumentUriUsingTree(it, path) }
                else -> null
            }
        }
        val id = b.optString("id")
        return if (root == "storage") storageFile(id).takeIf { id.isNotEmpty() && it.isFile } else uriFor(root, id)
    }

    /** Deletes or renames one entry and says how it went (`pb.x.fs.done`); the computer lists the folder again. */
    private fun change(peer: String, b: JSONObject, op: String) {
        val to = b.optString("to").trim()
        val reason = try {
            if (op == "rename" && !StoragePaths.validName(to)) "bad_name"
            else when (val t = target(b)) {
                is java.io.File -> fileOp(t, op, to)
                is Uri -> uriOp(t, op, to)
                else -> "unsupported"
            }
        } catch (e: SecurityException) {
            when {
                b.optString("root").startsWith("tree:") -> "read_only"
                Build.VERSION.SDK_INT >= 29 && e is android.app.RecoverableSecurityException -> "needs_all_files"
                else -> "no_permission"
            }
        } catch (_: Exception) { "failed" }
        synchronized(cache) { cache.clear() }
        Bridge.sendTo(peer, "pb.x.fs.done", JSONObject().put("op", op).put("name", b.optString("name"))
            .put("ok", reason == null).put("reason", reason ?: ""))
    }

    // Android 11+ routes these through MediaProvider, so the galleries notice the change by themselves.
    private fun fileOp(f: java.io.File, op: String, to: String): String? {
        if (!f.exists()) return "missing"
        if (op == "delete") return if (f.deleteRecursively()) null else "failed"
        val dest = java.io.File(f.parentFile, to)
        if (dest.exists()) return "exists"
        return if (f.renameTo(dest)) null else "failed"
    }

    private fun uriOp(u: Uri, op: String, to: String): String? {
        val r = ctx.contentResolver
        val doc = DocumentsContract.isDocumentUri(ctx, u)
        val ok = when {
            op == "delete" && doc -> DocumentsContract.deleteDocument(r, u)
            op == "delete" -> r.delete(u, null, null) > 0
            doc -> DocumentsContract.renameDocument(r, u, to) != null
            else -> r.update(u, android.content.ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, to) }, null, null) > 0
        }
        return if (ok) null else "failed"
    }

    /** A transfer ended: close the descriptor opened for it. */
    fun finished(transferId: String) {
        sending.remove(transferId)?.close()
    }

    // --- tell the computer when the library changes -----------------------------------------------------

    private fun watch() {
        if (observer != null) return
        val o = object : ContentObserver(main) {
            private val tell = Runnable {
                synchronized(cache) { cache.clear() }
                watchers.entries.removeIf { System.currentTimeMillis() - it.value > 600_000 }
                if (watchers.isEmpty()) {
                    ctx.contentResolver.unregisterContentObserver(this)
                    observer = null
                } else {
                    watchers.keys.forEach { Bridge.sendTo(it, "pb.x.fs.changed", JSONObject()) }
                }
            }

            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(tell)
                main.postDelayed(tell, 1500)
            }
        }
        observer = o
        for (u in listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, MediaStore.Audio.Media.EXTERNAL_CONTENT_URI)) {
            try {
                ctx.contentResolver.registerContentObserver(u, true, o)
            } catch (_: Exception) {}
        }
        if (Build.VERSION.SDK_INT >= 29) ctx.contentResolver.registerContentObserver(MediaStore.Downloads.EXTERNAL_CONTENT_URI, true, o)
    }
}
