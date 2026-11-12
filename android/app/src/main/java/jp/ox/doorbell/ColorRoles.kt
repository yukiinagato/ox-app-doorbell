// The two colour rules every shell shares (docs/en/ui-guidelines.md, Tokens > Color). Pure, so
// both are host-tested.
package jp.ox.doorbell

internal object ColorRoles {
    /** A colour used as a container next to the surface must stand off it by this much. */
    const val PRIMARY_MIN_CONTRAST = 3.0

    /** A role colour used as text or an outline must reach this against its surface. */
    const val TEXT_MIN_CONTRAST = 4.5

    /**
     * The application's primary role as (fill, ink), or null to keep the platform's baseline
     * primary. Only a call-button colour an administrator chose becomes the primary, and only
     * when it reaches 3:1 against the surface. The accent Core computes on its own from the
     * wallpaper is for the door station's Call button and never recolours the application.
     */
    fun primary(administratorRgb: Int?, surfaceRgb: Int): Pair<Int, Int>? {
        val fill = (administratorRgb ?: return null) and 0xffffff
        if (UiStylePolicy.contrast(fill, surfaceRgb and 0xffffff) < PRIMARY_MIN_CONTRAST) return null
        val ink = if (UiStylePolicy.contrast(0xFFFFFF, fill) >= UiStylePolicy.contrast(0x111111, fill))
            0xFFFFFF else 0x111111
        return fill to ink
    }

    /**
     * [roleRgb] as text or an outline on [surfaceRgb]: unchanged when it already reaches 4.5:1,
     * otherwise moved toward white on a dark surface or black on a light one until it does. This
     * is why the dark appearance shows a lighter red for "Delete" than the red it uses as a fill.
     */
    fun asText(roleRgb: Int, surfaceRgb: Int): Int {
        val role = roleRgb and 0xffffff
        val surface = surfaceRgb and 0xffffff
        if (UiStylePolicy.contrast(role, surface) >= TEXT_MIN_CONTRAST) return role
        val toward = if (UiStylePolicy.contrast(0xFFFFFF, surface) >=
            UiStylePolicy.contrast(0x000000, surface)) 0xFFFFFF else 0x000000
        for (step in 1..20) {
            val mixed = mix(role, toward, step / 20f)
            if (UiStylePolicy.contrast(mixed, surface) >= TEXT_MIN_CONTRAST) return mixed
        }
        return toward
    }

    private fun mix(from: Int, to: Int, amount: Float): Int {
        fun channel(shift: Int): Int {
            val a = from ushr shift and 0xff
            val b = to ushr shift and 0xff
            return (a + (b - a) * amount + 0.5f).toInt().coerceIn(0, 255)
        }
        return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }
}
