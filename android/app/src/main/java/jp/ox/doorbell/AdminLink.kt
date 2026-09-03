// The administration-page address and its QR, shown on every indoor screen (spec §4.1, §5.1,
// §5.2). Opening the page still asks for the 管理パスワード, so the QR is safe to leave visible.
package jp.ox.doorbell

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import org.json.JSONObject

internal data class AdminLink(val url: String, val leaderUrl: String) {
    val hasLeader: Boolean get() = leaderUrl.isNotEmpty() && leaderUrl != url
}

/**
 * QR bitmaps for the administration link, cached by (url, size).
 *
 * Encoding a QR and rasterising it is not free, and the dashboard footer was regenerating one on
 * every status poll -- several times a second on a busy cluster, all on the main thread. The
 * address only changes when the node's own IP or port does, so the bitmap is built once and reused
 * until it does.
 */
internal object AdminQrCache {

    private val cache = HashMap<String, android.graphics.Bitmap>(4)

    fun get(core: DoorbellCore, url: String, sidePx: Int): android.graphics.Bitmap? {
        if (url.isEmpty() || sidePx <= 0) return null
        val key = "$url@$sidePx"
        cache[key]?.let { if (!it.isRecycled) return it }
        val bitmap = try { PairingUi.qrBitmap(core, url, sidePx) } catch (_: Exception) { null }
            ?: return null
        // A handful of sizes and one address; bound it anyway so a flapping IP cannot grow it.
        if (cache.size >= MAX_ENTRIES) cache.clear()
        cache[key] = bitmap
        return bitmap
    }

    fun clear() {
        cache.clear()
    }

    private const val MAX_ENTRIES = 6
}

internal object AdminLinks {

    /**
     * Build this node's admin URL from its own mesh addresses, and the leader's when a different
     * node holds that duty. Falls back to loopback so the row is never blank.
     */
    fun resolve(status: JSONObject?, httpPort: Int): AdminLink {
        // status.node carries local_addrs; "addrs" only exists on peer entries, and reading that
        // here left the dashboard QR pointing at 127.0.0.1, which no other device can open.
        val node = status?.optJSONObject("node")
        val self = firstHost(node?.optJSONArray("local_addrs"))
            ?: firstHost(node?.optJSONArray("addrs"))
        val local = "http://${self ?: "127.0.0.1"}:$httpPort/admin/"
        val peers = status?.optJSONArray("peers")
        var leader = ""
        if (peers != null) {
            for (index in 0 until peers.length()) {
                val peer = peers.optJSONObject(index) ?: continue
                if (!peer.optBoolean("leader")) continue
                val host = firstHost(peer.optJSONArray("addrs")) ?: continue
                leader = "http://$host:$httpPort/admin/"
                break
            }
        }
        return AdminLink(local, leader)
    }

    /** Mesh addresses are host:port; the admin page lives on the HTTP port, not that one. */
    internal fun firstHost(addresses: org.json.JSONArray?): String? {
        if (addresses == null) return null
        for (index in 0 until addresses.length()) {
            val value = addresses.optString(index)
            if (value.isEmpty()) continue
            val separator = value.lastIndexOf(':')
            val host = if (separator > 0) value.substring(0, separator) else value
            if (host.isNotEmpty()) return host
        }
        return null
    }

    /**
     * The footer block: a small QR next to the address. [sizeDp] keeps it unobtrusive in the
     * corner of the incoming screen and readable in the dashboard footer.
     */
    fun view(
        context: Context,
        palette: Palette,
        core: DoorbellCore,
        link: AdminLink,
        caption: String,
        sizeDp: Int,
    ): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val side = ShellUi.dp(context, sizeDp)
        val bitmap = AdminQrCache.get(core, link.url, side)
        if (bitmap != null) {
            addView(
                ImageView(context).apply {
                    setImageBitmap(bitmap)
                    contentDescription = caption
                    background = ShellUi.rounded(context, 0xFFFFFF, 4)
                    val pad = ShellUi.dp(context, 2)
                    setPadding(pad, pad, pad, pad)
                },
                LinearLayout.LayoutParams(side, side),
            )
        }
        val texts = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val gap = ShellUi.dp(context, 8)
            setPadding(gap, 0, 0, 0)
        }
        texts.addView(ShellUi.text(context, caption, 11.5f, palette.muted))
        texts.addView(
            ShellUi.text(context, link.url, 12f, palette.ink).apply {
                maxLines = 1
                isSingleLine = true
            },
        )
        if (link.hasLeader)
            texts.addView(ShellUi.text(context, link.leaderUrl, 11.5f, palette.muted).apply {
                maxLines = 1
                isSingleLine = true
            })
        addView(
            texts,
            LinearLayout.LayoutParams(0, android.view.ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    }
}
