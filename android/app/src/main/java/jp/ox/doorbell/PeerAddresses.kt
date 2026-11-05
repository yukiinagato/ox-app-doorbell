// Mesh addresses as Core reports them: "host:port", "[v6]:port", or a bare host.
//
// Peers can publish several addresses (Wi-Fi, Ethernet, VPN, IPv6 link-local). Callers that must
// reach a peer directly -- only SIP does, since media goes through the loopback proxy -- take the
// candidates in a stable preference order rather than whatever happened to be listed first.
package jp.ox.doorbell

import org.json.JSONArray

internal object PeerAddresses {

    /** The host part of one mesh address, without brackets or port; null when empty. */
    fun host(address: String): String? {
        val value = address.trim()
        if (value.isEmpty()) return null
        if (value.startsWith("[")) {
            val close = value.indexOf(']')
            return if (close > 1) value.substring(1, close) else null
        }
        val colons = value.count { it == ':' }
        // A bare IPv6 literal has several colons and no port.
        if (colons > 1) return value
        val separator = value.lastIndexOf(':')
        val host = if (separator > 0) value.substring(0, separator) else value
        return host.ifEmpty { null }
    }

    /** Distinct hosts ordered: private/global IPv4, other names, global IPv6, link-local last. */
    fun preferredHosts(addresses: JSONArray?): List<String> {
        if (addresses == null) return emptyList()
        val hosts = LinkedHashSet<String>()
        for (index in 0 until addresses.length()) host(addresses.optString(index))?.let(hosts::add)
        return hosts.sortedBy(::rank)
    }

    fun first(addresses: JSONArray?): String? = preferredHosts(addresses).firstOrNull()

    /** A host formatted for a URI authority: IPv6 literals are bracketed. */
    fun authority(host: String, port: Int): String =
        (if (host.contains(':')) "[$host]" else host) + ":$port"

    private fun rank(host: String): Int {
        val lower = host.lowercase()
        return when {
            lower.startsWith("169.254.") -> 4
            lower.startsWith("127.") || lower == "::1" -> 5
            lower.startsWith("fe80:") -> 4
            lower.contains(':') -> 2
            lower.all { it.isDigit() || it == '.' } -> 0
            else -> 1
        }
    }
}
