package jp.keihan.doorbell

import android.media.MediaCodec
import android.os.Build
import java.nio.ByteBuffer

/** MediaCodec changed from buffer arrays to per-index accessors in API 21. */
internal interface CodecBufferAccess {
    fun afterStart(codec: MediaCodec)
    fun input(codec: MediaCodec, index: Int): ByteBuffer?
    fun output(codec: MediaCodec, index: Int): ByteBuffer?
    fun onOutputBuffersChanged(codec: MediaCodec)
}

internal object CodecBufferAccessFactory {
    fun create(): CodecBufferAccess =
        if (Build.VERSION.SDK_INT >= 21) Api21CodecBufferAccess() else Api16CodecBufferAccess()
}

@Suppress("DEPRECATION")
private class Api16CodecBufferAccess : CodecBufferAccess {
    private var inputs: Array<ByteBuffer> = emptyArray()
    private var outputs: Array<ByteBuffer> = emptyArray()

    override fun afterStart(codec: MediaCodec) {
        inputs = codec.inputBuffers
        outputs = codec.outputBuffers
    }

    override fun input(codec: MediaCodec, index: Int): ByteBuffer? = inputs.getOrNull(index)

    override fun output(codec: MediaCodec, index: Int): ByteBuffer? = outputs.getOrNull(index)

    override fun onOutputBuffersChanged(codec: MediaCodec) {
        outputs = codec.outputBuffers
    }
}
