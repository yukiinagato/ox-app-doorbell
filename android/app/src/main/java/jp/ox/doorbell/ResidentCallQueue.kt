package jp.ox.doorbell

internal class ResidentCallQueue {
    data class Key(val door: String, val callId: String)
    data class Item(val key: Key, val revision: Int, val purpose: String = "",
                    val language: String = "", val expiry: Long = 0L)
    private val entries = linkedMapOf<Key, Item>()
    private val retired = mutableMapOf<Key, Int>()
    var selected: Key? = null
        private set
    val items: List<Item> get() = entries.values.toList()
    fun admit(item: Item) {
        if (item.key.door.isEmpty() || item.key.callId.isEmpty() || item.revision < 0 ||
            item.revision <= (retired[item.key] ?: -1) ||
            item.revision < (entries[item.key]?.revision ?: -1)) return
        entries[item.key] = item
        if (selected == null) selected = item.key
    }
    fun select(key: Key): Item? = entries[key]?.also { selected = key }
    fun retire(key: Key, revision: Int) {
        if (key.door.isEmpty() || key.callId.isEmpty() || revision < 0) return
        retired[key] = maxOf(retired[key] ?: -1, revision)
        if ((entries[key]?.revision ?: Int.MAX_VALUE) <= revision) entries.remove(key)
    }
}
