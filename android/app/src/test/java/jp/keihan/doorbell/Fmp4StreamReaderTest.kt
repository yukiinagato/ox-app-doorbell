package jp.keihan.doorbell

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Fmp4StreamReaderTest {
    @Test fun parsesRepositoryLiveFragmentShape() {
        val sps = byteArrayOf(0x67, 66, 0, 30)
        val pps = byteArrayOf(0x68, 0)
        val config = avcConfig(sps, pps)
        val avc1Body = ByteArrayOutputStream().also { out ->
            val fixed = ByteArray(78)
            fixed[24] = 0x02; fixed[25] = 0x80.toByte() // 640
            fixed[26] = 0x01; fixed[27] = 0x68          // 360
            out.write(fixed)
            out.write(box("avcC", config))
        }.toByteArray()
        val stsd = ByteArrayOutputStream().also { out ->
            out.write(ByteArray(8))
            out.write(box("avc1", avc1Body))
        }.toByteArray()
        val stbl = box("stbl", box("stsd", stsd))
        val minf = box("minf", stbl)
        val mdia = box("mdia", minf)
        val trak = box("trak", mdia)
        val moov = box("moov", trak)

        val nal = byteArrayOf(0x65, 1, 2)
        val avccSample = ByteArrayOutputStream().also { out ->
            DataOutputStream(out).writeInt(nal.size)
            out.write(nal)
        }.toByteArray()
        val trun = ByteArrayOutputStream().also { out ->
            val data = DataOutputStream(out)
            data.writeByte(0); data.writeByte(0); data.writeByte(7); data.writeByte(1)
            data.writeInt(1)
            data.writeInt(0)
            data.writeInt(40)
            data.writeInt(avccSample.size)
            data.writeInt(0x02000000)
        }.toByteArray()
        val moof = box("moof", box("traf", box("trun", trun)))
        val dbts = ByteArrayOutputStream().also { out ->
            val data = DataOutputStream(out)
            data.writeInt(1)
            data.writeLong(1_700_000_000_000L)
        }.toByteArray()
        val stream = ByteArrayOutputStream().also { out ->
            out.write(box("ftyp", byteArrayOf(0, 0, 0, 0)))
            out.write(moov)
            out.write(box("dbts", dbts))
            out.write(moof)
            out.write(box("mdat", avccSample))
        }.toByteArray()

        val configs = ArrayList<Fmp4StreamReader.Config>()
        val samples = ArrayList<Fmp4StreamReader.Sample>()
        Fmp4StreamReader(ByteArrayInputStream(stream), object : Fmp4StreamReader.Listener {
            override fun onConfig(config: Fmp4StreamReader.Config) { configs.add(config) }
            override fun onSample(sample: Fmp4StreamReader.Sample) { samples.add(sample) }
        }).pump { true }

        assertEquals(1, configs.size)
        assertEquals(640, configs[0].width)
        assertEquals(360, configs[0].height)
        assertArrayEquals(sps, configs[0].sps)
        assertEquals(1, samples.size)
        assertTrue(samples[0].keyframe)
        assertEquals(1_700_000_000_000L, samples[0].captureMs)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x65, 1, 2), samples[0].annexB)
    }

    private fun avcConfig(sps: ByteArray, pps: ByteArray): ByteArray =
        ByteArrayOutputStream().also { out ->
            val data = DataOutputStream(out)
            data.write(byteArrayOf(1, 66, 0, 30, 0xff.toByte(), 0xe1.toByte()))
            data.writeShort(sps.size); data.write(sps)
            data.writeByte(1); data.writeShort(pps.size); data.write(pps)
        }.toByteArray()

    private fun box(type: String, body: ByteArray): ByteArray =
        ByteArrayOutputStream().also { out ->
            val data = DataOutputStream(out)
            data.writeInt(body.size + 8)
            data.writeBytes(type)
            data.write(body)
        }.toByteArray()
}
