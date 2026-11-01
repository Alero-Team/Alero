package dev.alero.app

/** Only live notification actions are retained; wall-clock changes cannot extend their life. */
internal class ReplyTargets<T>(private val limit: Int = 50, private val ttl: Long = 3_600_000) {
    private val items = LinkedHashMap<String, Pair<Long, T>>()

    @Synchronized fun put(key: String, target: T, now: Long) {
        items.entries.removeIf { now - it.value.first >= ttl }
        items.remove(key)
        items[key] = now to target
        while (items.size > limit) items.remove(items.keys.first())
    }

    @Synchronized fun get(key: String, now: Long): T? {
        val item = items[key] ?: return null
        if (now - item.first >= ttl) { items.remove(key); return null }
        return item.second
    }

    @Synchronized fun remove(key: String) { items.remove(key) }
    @Synchronized fun clear() { items.clear() }
}
