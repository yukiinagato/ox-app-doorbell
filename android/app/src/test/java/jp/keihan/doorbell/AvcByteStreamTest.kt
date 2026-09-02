package jp.keihan.doorbell

import android.media.MediaCodecInfo
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AvcByteStreamTest {
    @Test fun convertsNv21ToNv12AndI420() {
        val nv21 = byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 10, 20, 11, 21)
        val semi = ByteBuffer.allocate(12)
        val planar = ByteBuffer.allocate(12)

        AvcByteStream.copyNv21(nv21, 4, 2,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar, semi)
        AvcByteStream.copyNv21(nv21, 4, 2,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar, planar)

        assertArrayEquals(byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 20, 10, 21, 11), semi.array())
        assertArrayEquals(byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 20, 21, 10, 11), planar.array())
    }

    @Test fun normalizesAvccAndReadsBaselineProfile() {
        val avcc = byteArrayOf(0, 0, 0, 4, 0x67, 66, 0, 30,
                               0, 0, 0, 2, 0x68, 0)
        val annexB = AvcByteStream.toAnnexB(avcc)!!
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x67, 66, 0, 30,
                                      0, 0, 0, 1, 0x68, 0), annexB)
        assertEquals(66, AvcByteStream.profileIdc(annexB))
    }

    @Test fun rejectsTruncatedAvcc() {
        assertNull(AvcByteStream.toAnnexB(byteArrayOf(0, 0, 0, 0x40, 1, 2)))
    }
}
