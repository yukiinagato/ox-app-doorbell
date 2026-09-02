package jp.ox.doorbell

import android.annotation.TargetApi
import android.media.MediaCodec
import java.nio.ByteBuffer

/** Kept in a separate class so Dalvik on API 19 never verifies API 21 symbols. */
@TargetApi(21)
internal class Api21CodecBufferAccess : CodecBufferAccess {
    override fun afterStart(codec: MediaCodec) = Unit
    override fun input(codec: MediaCodec, index: Int): ByteBuffer? = codec.getInputBuffer(index)
    override fun output(codec: MediaCodec, index: Int): ByteBuffer? = codec.getOutputBuffer(index)
    override fun onOutputBuffersChanged(codec: MediaCodec) = Unit
}
