package dev.alero.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The computer can only pass a dialable number to the phone, never a URI or anything else. */
class CallNumberTest {
    @Test fun numbersAreCleaned() {
        assertEquals("+34600123456", Calls.cleanNumber(" +34 600-123 456 "))
        assertEquals("911234567", Calls.cleanNumber("(91) 123.45.67"))
    }

    @Test fun anythingElseIsRefused() {
        for (bad in listOf("", "   ", "abc", "tel:123", "123;rm", "+", "1".repeat(33), "112\n113", "*#06#", "*21*600123456#", "**04*0000*1111*1111#", "#31#600123456", "600+123")) assertNull(bad, Calls.cleanNumber(bad))
    }
}
