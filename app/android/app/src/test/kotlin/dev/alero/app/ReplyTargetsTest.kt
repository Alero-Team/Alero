package dev.alero.app

import org.junit.Assert.*
import org.junit.Test

class ReplyTargetsTest {
    @Test fun removesExpiredRemovedAndOldestTargets() {
        val cache = ReplyTargets<String>(2, 100)
        cache.put("a", "first", 0)
        cache.put("b", "second", 1)
        cache.put("c", "third", 2)
        assertNull(cache.get("a", 2))
        assertEquals("second", cache.get("b", 100))
        assertNull(cache.get("b", 101))
        cache.remove("c")
        assertNull(cache.get("c", 3))
        cache.put("d", "fourth", 4)
        cache.clear()
        assertNull(cache.get("d", 5))
    }
}
