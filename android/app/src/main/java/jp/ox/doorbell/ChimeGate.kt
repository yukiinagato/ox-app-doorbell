package jp.ox.doorbell

/** Process-local replay/expiry gate for the targeted schema-v2 chime contract. */
internal class ChimeGate {
    private val seen = LinkedHashSet<String>()

    @Synchronized
    fun accept(schemaVersion: Int, callId: String, stageRevision: Int,
               expiresAtMs: Long, nowMs: Long): Boolean {
        if (schemaVersion < 2 || callId.isEmpty()) return false
        if (expiresAtMs > 0L && expiresAtMs <= nowMs) return false
        val key = "$callId:$stageRevision"
        if (!seen.add(key)) return false
        while (seen.size > MAX_SEEN) seen.remove(seen.first())
        return true
    }

    companion object {
        private const val MAX_SEEN = 64
    }
}
