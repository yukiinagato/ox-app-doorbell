package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ColorRolesTest {
    private val lightSurface = 0xF9F9FF
    private val darkSurface = 0x111318

    @Test
    fun onlyAnAdministratorsColourBecomesThePrimaryRole() {
        // Nothing chosen: Core's computed accent is not consulted at all.
        assertNull(ColorRoles.primary(null, lightSurface))
        assertEquals(0x1E6FB8 to 0xFFFFFF, ColorRoles.primary(0x1E6FB8, lightSurface))
        assertEquals(0xFFD166 to 0x111111, ColorRoles.primary(0xFFD166, darkSurface))
    }

    @Test
    fun aChosenColourTooCloseToTheSurfaceKeepsTheBaselinePrimary() {
        assertNull(ColorRoles.primary(0xF0F0F5, lightSurface))
        assertNull(ColorRoles.primary(0x1A1C20, darkSurface))
        // The same colour is fine where it stands off the surface.
        assertEquals(0x1A1C20, ColorRoles.primary(0x1A1C20, lightSurface)!!.first)
    }

    @Test
    fun aRoleColourUsedAsTextReachesFourPointFiveToOneInBothAppearances() {
        val negativeFill = 0xB02A25
        // Readable on the light surface as it is.
        assertEquals(negativeFill, ColorRoles.asText(negativeFill, lightSurface))
        // Too dark on the dark surface: a lighter red, still a red.
        val onDark = ColorRoles.asText(negativeFill, darkSurface)
        assertNotEquals(negativeFill, onDark)
        assertTrue(UiStylePolicy.contrast(onDark, darkSurface) >= 4.5)
        assertTrue((onDark ushr 16 and 0xff) > (onDark and 0xff))
        for (role in listOf(0x4CC277, 0xF0B44C, 0x9ECAFF, 0x7F5B3A, 0x808080))
            for (surface in listOf(lightSurface, darkSurface, 0xE2E2E9, 0x33353A))
                assertTrue(
                    "role %06x on %06x".format(role, surface),
                    UiStylePolicy.contrast(ColorRoles.asText(role, surface), surface) >= 4.5,
                )
    }
}
