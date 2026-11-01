package dev.alero.app

internal object FileOpening {
    const val APK = "application/vnd.android.package-archive"

    fun mime(name: String, reported: String?, byExtension: String?): String = when {
        name.substringAfterLast('.', "").equals("apk", ignoreCase = true) -> APK
        reported.isNullOrBlank() || reported == "application/octet-stream" -> byExtension ?: "application/octet-stream"
        else -> reported
    }
}
