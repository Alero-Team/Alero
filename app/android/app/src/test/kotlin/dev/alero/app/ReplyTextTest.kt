package dev.alero.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Alero refuses only empty replies or a broken key, never long ones (the messaging app sets its own limits). */
class ReplyTextTest {
    @Test fun longRepliesAreAccepted() {
        for (n in listOf(100, 500, 1_000, 5_000, 10_000, 60_000)) assertNull(NotifListener.replyTextError("a".repeat(n), "k"))
        assertNull(NotifListener.replyTextError("👋🏽 párrafo\n\notro 👨‍👩‍👧‍👦".repeat(500), "k"))
    }

    @Test fun emptyOrKeylessIsRefused() {
        assertEquals("invalid_text", NotifListener.replyTextError("  \n", "k"))
        assertEquals("invalid_text", NotifListener.replyTextError("hola", ""))
    }
}
