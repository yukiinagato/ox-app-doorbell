package jp.ox.doorbell

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PeerAddressesTest {

    @Test
    fun hostsParseIpv4Ipv6AndBareForms() {
        assertEquals("10.0.0.5", PeerAddresses.host("10.0.0.5:47172"))
        assertEquals("fd00::5", PeerAddresses.host("[fd00::5]:47172"))
        assertEquals("fd00::5", PeerAddresses.host("fd00::5"))
        assertEquals("door.local", PeerAddresses.host("door.local"))
        assertNull(PeerAddresses.host(""))
        assertNull(PeerAddresses.host("[]:1"))
    }

    @Test
    fun ipv4IsPreferredAndLinkLocalComesLast() {
        val addrs = JSONArray()
            .put("[fe80::1]:47172")
            .put("169.254.3.4:47172")
            .put("[fd00::5]:47172")
            .put("192.168.1.20:47172")
        assertEquals(
            listOf("192.168.1.20", "fd00::5", "fe80::1", "169.254.3.4"),
            PeerAddresses.preferredHosts(addrs),
        )
        assertEquals("192.168.1.20", PeerAddresses.first(addrs))
        assertNull(PeerAddresses.first(null))
    }

    @Test
    fun ipv6AuthoritiesAreBracketed() {
        assertEquals("[fd00::5]:47190", PeerAddresses.authority("fd00::5", 47190))
        assertEquals("10.0.0.5:47190", PeerAddresses.authority("10.0.0.5", 47190))
    }

    @Test
    fun onlyLoopbackHostsReceiveTheLocalToken() {
        assertEquals(true, LocalMedia.isLoopbackHost("127.0.0.1"))
        assertEquals(true, LocalMedia.isLoopbackHost("localhost"))
        assertEquals(true, LocalMedia.isLoopbackHost("[::1]"))
        assertEquals(false, LocalMedia.isLoopbackHost("10.0.0.5"))
        assertEquals(false, LocalMedia.isLoopbackHost(null))
    }
}
