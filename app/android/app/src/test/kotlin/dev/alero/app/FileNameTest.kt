package dev.alero.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A rename asked by the computer must stay a plain name in the same folder. */
class FileNameTest {
    @Test fun plainNamesPass() {
        for (ok in listOf("foto.jpg", "Informe final (2).pdf", "día 1", ".nomedia")) assertTrue(ok, StoragePaths.validName(ok))
    }

    @Test fun pathsAndOddNamesAreRefused() {
        for (bad in listOf("", ".", "..", "a/b", "a\\b", "x:y", "a*b", "a\u0000b", "n".repeat(256))) assertFalse(bad, StoragePaths.validName(bad))
    }
}
