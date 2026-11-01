package dev.alero.app

import java.io.File

/** Canonical containment also refuses symlinks that lead outside shared storage. */
internal object StoragePaths {
    fun count(folder: File): Long = try {
        java.nio.file.Files.newDirectoryStream(folder.toPath()).use { children ->
            var count = 0L
            val iterator = children.iterator()
            while (count < 1000 && iterator.hasNext()) { iterator.next(); count++ }
            count
        }
    } catch (_: Exception) { -1L }

    fun resolve(root: File, path: String): File {
        val base = root.canonicalFile
        val file = if (path.isEmpty()) base else File(base, path).canonicalFile
        if (file != base && !file.path.startsWith(base.path + File.separator)) throw SecurityException("path")
        val relative = file.relativeTo(base).invariantSeparatorsPath
        if (relative == "Android/data" || relative.startsWith("Android/data/") ||
            relative == "Android/obb" || relative.startsWith("Android/obb/")) throw SecurityException("private")
        if (relative.split('/').any { it == ".trash-storage" }) throw SecurityException("trash")
        return file
    }
}
