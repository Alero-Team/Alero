package dev.alero.app

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class StoragePathsTest {
    @Test fun permissionDeniedCountIsUnknown() {
        val root = Files.createTempDirectory("alero-denied").toFile()
        val path = root.toPath()
        val acl = Files.getFileAttributeView(path, java.nio.file.attribute.AclFileAttributeView::class.java)
        val originalAcl = acl?.acl
        val posix = Files.getFileAttributeView(path, java.nio.file.attribute.PosixFileAttributeView::class.java)
        val originalPosix = posix?.readAttributes()?.permissions()
        try {
            if (acl != null) {
                val deny = java.nio.file.attribute.AclEntry.newBuilder()
                    .setType(java.nio.file.attribute.AclEntryType.DENY)
                    .setPrincipal(Files.getOwner(path))
                    .setPermissions(java.nio.file.attribute.AclEntryPermission.LIST_DIRECTORY)
                    .build()
                acl.acl = listOf(deny) + originalAcl!!
            } else {
                org.junit.Assume.assumeNotNull(posix)
                posix!!.setPermissions(emptySet())
                org.junit.Assume.assumeFalse(Files.isReadable(path))
            }
            assertEquals(-1L, StoragePaths.count(root))
        } finally {
            if (originalAcl != null) acl!!.acl = originalAcl
            if (originalPosix != null) posix!!.setPermissions(originalPosix)
            root.delete()
        }
    }
    @Test fun countsChildrenAndReportsUnreadableWithoutFakeZero() {
        val root = Files.createTempDirectory("alero-count").toFile()
        try {
            assertEquals(0L, StoragePaths.count(root))
            repeat(3) { File(root, "$it.txt").createNewFile() }
            assertEquals(3L, StoragePaths.count(root))
            assertEquals(-1L, StoragePaths.count(File(root, "missing")))
            assertEquals(-1L, StoragePaths.count(File(root, "0.txt")))
            repeat(1001) { File(root, "cap-$it").createNewFile() }
            assertEquals(1000L, StoragePaths.count(root))
        } finally { root.deleteRecursively() }
    }

    @Test fun confinesRequestsToSharedStorage() {
        val root = Files.createTempDirectory("alero-paths").toFile()
        try {
            assertEquals(root.canonicalFile, StoragePaths.resolve(root, ""))
            assertEquals(File(root, "Music/song.mp3").canonicalFile, StoragePaths.resolve(root, "Music/song.mp3"))
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "../outside") }
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "Android/data/other.app/private") }
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "Android/obb") }
            assertEquals(File(root, "Android/media").canonicalFile, StoragePaths.resolve(root, "Android/media"))
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, ".trash-storage") }
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, ".trash-storage/DCIM/file.jpg") }
            assertThrows(SecurityException::class.java) { StoragePaths.resolve(root, "Pictures/.trash-storage/file.jpg") }
            assertEquals(File(root, ".visible-hidden").canonicalFile, StoragePaths.resolve(root, ".visible-hidden"))
        } finally { root.delete() }
    }
}
