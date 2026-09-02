package jp.keihan.doorbell

internal enum class NativeKioskHealth(val wireValue: String) {
    UNKNOWN("unknown"),
    UNAVAILABLE("unavailable"),
    HEALTHY("healthy"),
    UNHEALTHY("unhealthy"),
}

internal class NativeKioskHealthTracker(
    initial: NativeKioskHealth,
    private val failuresRequired: Int = 3,
) {
    var health: NativeKioskHealth = initial
        private set
    var consecutiveFailures: Int = 0
        private set

    fun unavailable(): NativeKioskHealth {
        consecutiveFailures = 0
        health = NativeKioskHealth.UNAVAILABLE
        return health
    }

    fun record(active: Boolean): NativeKioskHealth {
        if (active) {
            consecutiveFailures = 0
            health = NativeKioskHealth.HEALTHY
        } else {
            consecutiveFailures++
            health = if (consecutiveFailures >= failuresRequired.coerceAtLeast(1))
                NativeKioskHealth.UNHEALTHY else NativeKioskHealth.UNKNOWN
        }
        return health
    }
}

internal data class HelperModeDecision(
    val configured: String,
    val configValid: Boolean,
    val shouldUseHelper: Boolean,
    val targetEffective: String,
)

/** Pure fail-closed policy for the administrator-configured recovery helper mode. */
internal object HelperModePolicy {
    fun decide(
        rawMode: String?,
        helperInstalled: Boolean,
        nativeHealth: NativeKioskHealth,
    ): HelperModeDecision {
        val missing = rawMode.isNullOrBlank()
        val valid = missing || rawMode == "off" || rawMode == "auto" || rawMode == "on"
        val configured = when {
            missing -> "auto"
            valid -> rawMode!!
            else -> "off"
        }
        return when (configured) {
            "off" -> HelperModeDecision(configured, valid, false, "off")
            "on" -> HelperModeDecision(
                configured,
                valid,
                true,
                if (helperInstalled) "helper" else "helper_unavailable",
            )
            else -> when (nativeHealth) {
                NativeKioskHealth.HEALTHY ->
                    HelperModeDecision(configured, valid, false, "native_kiosk")
                NativeKioskHealth.UNKNOWN ->
                    HelperModeDecision(configured, valid, false, "awaiting_native_measurement")
                NativeKioskHealth.UNAVAILABLE, NativeKioskHealth.UNHEALTHY ->
                    HelperModeDecision(
                        configured,
                        valid,
                        helperInstalled,
                        if (helperInstalled) "helper" else "helper_unavailable",
                    )
            }
        }
    }
}
