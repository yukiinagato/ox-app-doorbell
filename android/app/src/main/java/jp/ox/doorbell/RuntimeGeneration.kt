package jp.ox.doorbell

import java.util.concurrent.atomic.AtomicLong

internal class RuntimeGeneration {
    private val current = AtomicLong(0L)

    fun begin(): Long = current.incrementAndGet()

    fun current(): Long = current.get()

    fun isCurrent(generation: Long): Boolean = generation == current.get()
}
