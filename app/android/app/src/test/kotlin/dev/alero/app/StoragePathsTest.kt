package dev.alero.app

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class StoragePathsTest {
    @Test fun confinesRequestsToSharedStorage() {
        val root = Files.createTempDirectory("alero-paths").toFile()
        try {
            assertEquals(root.canonicalFile, StoragePaths.resolve(root, ""))
            assertEquals(File(root, "Music/song.mp3").canonicalFile, StoragePaths.resolve(root, "Music/song.mp3"))
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "../outside") }
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "Android/data/other.app/private") }
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "Android/obb") }
            assertEquals(File(root, "Android/media").canonicalFile, StoragePaths.resolve(root, "Android/media"))
        } finally { root.delete() }
    }
}
