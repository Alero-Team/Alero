package dev.alero.app

import org.junit.Assert.assertEquals
import org.junit.Test

class FileOpeningTest {
    @Test fun apkOverridesGenericAndIncorrectMimeWithoutChangingOtherFiles() {
        assertEquals(FileOpening.APK, FileOpening.mime("UPDATE.APK", "application/octet-stream", null))
        assertEquals(FileOpening.APK, FileOpening.mime("update.apk", "text/plain", null))
        assertEquals("application/pdf", FileOpening.mime("manual.pdf", "application/octet-stream", "application/pdf"))
        assertEquals("image/png", FileOpening.mime("photo.png", "image/png", null))
        assertEquals("application/octet-stream", FileOpening.mime("unknown", null, null))
    }
}
