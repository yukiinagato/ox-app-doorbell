package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AirQualityModelTest {

    private fun parse(json: String) = AirQualityModel.parse(JSONObject(json))

    @Test
    fun hiddenWhenNotShownOrUnknown() {
        assertFalse(AirQualityModel.parse(null).visible)
        assertFalse(parse("""{"show":false,"state":"ok","pm25":12}""").visible)
        assertFalse(parse("""{"show":true,"state":"hidden"}""").visible)
        assertFalse(parse("""{"show":true,"state":"future_state"}""").visible)
        assertNull(AirQualityModel.statusKey(AirQualityReading.HIDDEN))
    }

    @Test
    fun okReadingCarriesValueLevelAndDot() {
        val r = parse("""{"show":true,"sensor":"s1","state":"ok","name":"Entrance","pm25":30,
            "level":"moderate","at_ms":1,"age_s":42,"battery_pct":80,"charging":true}""")
        assertEquals(AirState.OK, r.state)
        assertTrue(r.hasValue)
        assertFalse(r.dimmed)
        assertEquals(30, r.pm25)
        assertEquals(AirLevel.MODERATE, r.level)
        assertEquals(42L, r.ageSeconds)
        assertEquals(AirLevel.MODERATE.dotRgb, r.dotRgb)
        assertEquals("air.level_moderate", AirQualityModel.statusKey(r))
        assertEquals("PM2.5  30 µg/m³ · Moderate", AirQualityModel.line(r, "PM2.5", "µg/m³", "Moderate"))
    }

    @Test
    fun staleIsDimmedWithoutLevelDot() {
        val r = parse("""{"show":true,"state":"stale","pm25":80,"level":"unhealthy"}""")
        assertTrue(r.hasValue)
        assertTrue(r.dimmed)
        assertNull(r.dotRgb)
        assertEquals("air.stale", AirQualityModel.statusKey(r))
    }

    @Test
    fun placeholdersHaveNoValue() {
        val waiting = parse("""{"show":true,"state":"waiting","name":"Entrance"}""")
        assertFalse(waiting.hasValue)
        assertEquals("air.waiting", AirQualityModel.statusKey(waiting))
        assertEquals("PM2.5 · Waiting", AirQualityModel.line(waiting, "PM2.5", "µg/m³", "Waiting"))
        val none = parse("""{"show":true,"state":"unconfigured"}""")
        assertEquals("air.unconfigured", AirQualityModel.statusKey(none))
        // An ok document without a value cannot be drawn as a reading.
        assertEquals(AirState.WAITING, parse("""{"show":true,"state":"ok"}""").state)
    }

    @Test
    fun everyCoreLevelMapsToAStringKey() {
        for (level in AirLevel.values()) {
            val r = parse("""{"show":true,"state":"ok","pm25":1,"level":"${level.wire}"}""")
            assertEquals(level, r.level)
            assertEquals("air.level_${level.wire}", AirQualityModel.statusKey(r))
        }
        assertEquals(6, AirLevel.values().map { it.dotRgb }.toSet().size)
    }

    @Test
    fun sensorPickerListsConfiguredSensorsByName() {
        val config = JSONObject("""{"air_sensors":{
            "s_b":{"name":"Entrance","host":"n1"},"s_a":{"name":"balcony"},"s_c":{}}}""")
        assertEquals(listOf("s_a" to "balcony", "s_b" to "Entrance", "s_c" to "s_c"),
                     AirQualityModel.sensorOptions(config))
        assertTrue(AirQualityModel.sensorOptions(null).isEmpty())
    }
}
