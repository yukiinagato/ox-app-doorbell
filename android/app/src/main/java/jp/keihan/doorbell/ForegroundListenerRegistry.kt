// Routes Core UI events to the Activity that is actually in front.
//
// The pairing screen used to clear the single listener slot on its own onPause, which left the
// main UI silent after pairing because it had only registered once, in onCreate. Every Activity
// now binds in onResume and unbinds in onPause; a resumed Activity that is still bound is
// restored when the screen above it goes away, so no event stream is lost.
package jp.keihan.doorbell

internal class ForegroundListenerRegistry {

    private val lock = Any()
    private val stack = ArrayList<DoorbellCore.Listener>(4)

    /** Foreground destination for Core events, or null when no Activity is resumed. */
    val current: DoorbellCore.Listener?
        get() = synchronized(lock) { stack.lastOrNull() }

    /** Called from onResume. Re-binding an already bound listener promotes it to the front. */
    fun bind(listener: DoorbellCore.Listener) {
        synchronized(lock) {
            stack.remove(listener)
            stack.add(listener)
            while (stack.size > MAX_DEPTH) stack.removeAt(0)
        }
    }

    /** Called from onPause and onDestroy. Unbinding a background listener never steals the slot. */
    fun unbind(listener: DoorbellCore.Listener) {
        synchronized(lock) { stack.remove(listener) }
    }

    fun isBound(listener: DoorbellCore.Listener): Boolean =
        synchronized(lock) { stack.contains(listener) }

    fun depth(): Int = synchronized(lock) { stack.size }

    private companion object {
        // Bounded so a leaked Activity reference cannot grow without limit.
        const val MAX_DEPTH = 8
    }
}
