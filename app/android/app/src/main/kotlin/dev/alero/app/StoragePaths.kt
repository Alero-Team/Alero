package dev.alero.app

import java.io.File

/** Canonical containment also refuses symlinks that lead outside shared storage. */
internal object StoragePaths {
    fun resolve(root: File, path: String): File {
        val base = root.canonicalFile
        val file = if (path.isEmpty()) base else File(base, path).canonicalFile
        if (file != base && !file.path.startsWith(base.path + File.separator)) throw SecurityException("path")
        val relative = file.relativeTo(base).invariantSeparatorsPath
        if (relative == "Android/data" || relative.startsWith("Android/data/") ||
            relative == "Android/obb" || relative.startsWith("Android/obb/")) throw SecurityException("private")
        return file
    }
}
