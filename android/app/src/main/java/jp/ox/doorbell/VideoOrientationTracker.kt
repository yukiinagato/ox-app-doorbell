package jp.ox.doorbell

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.view.Surface
import android.view.WindowManager
import kotlin.math.abs
import kotlin.math.max

/** Converts gravity into stable quarter turns for the service-owned camera pipeline. */
internal class VideoOrientationTracker(
    context: Context,
    private val handler: Handler,
    private val cameraRotation: (Int) -> Int,
    private val publish: (Int) -> Unit,
) : SensorEventListener {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val window = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val classifier = GravityOrientationClassifier()
    private var sensor: Sensor? = null
    private var published = -1

    @Suppress("DEPRECATION")
    fun start() {
        stop()
        val displayRotation = when (window.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        publishDeviceRotation(displayRotation)
        sensor = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        sensor?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME, handler)
        }
    }

    fun stop() {
        sensors.unregisterListener(this)
        sensor = null
        classifier.reset()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        if (event.values.size < 2) return
        classifier.observe(event.values[0], event.values[1])?.let(::publishDeviceRotation)
    }

    private fun publishDeviceRotation(deviceRotation: Int) {
        val rotation = cameraRotation(deviceRotation)
        if (rotation == published) return
        published = rotation
        publish(rotation)
    }
}

/** Two matching samples prevent noisy boundary crossings from rotating every video frame. */
internal class GravityOrientationClassifier {
    private var candidate = -1
    private var candidateSamples = 0
    private var committed = -1

    fun observe(x: Float, y: Float): Int? {
        val ax = abs(x)
        val ay = abs(y)
        if (max(ax, ay) < MIN_IN_PLANE_GRAVITY || abs(ax - ay) < AXIS_MARGIN) return null
        val value = if (ax > ay) {
            if (x > 0) 90 else 270
        } else {
            if (y > 0) 0 else 180
        }
        if (value != candidate) {
            candidate = value
            candidateSamples = 1
            return null
        }
        candidateSamples++
        if (candidateSamples < REQUIRED_SAMPLES || value == committed) return null
        committed = value
        return value
    }

    fun reset() {
        candidate = -1
        candidateSamples = 0
        committed = -1
    }

    companion object {
        private const val MIN_IN_PLANE_GRAVITY = 4f
        private const val AXIS_MARGIN = 1.25f
        private const val REQUIRED_SAMPLES = 2
    }
}
