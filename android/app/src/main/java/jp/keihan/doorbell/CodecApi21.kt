package jp.keihan.doorbell

import android.annotation.TargetApi
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat

@TargetApi(21)
internal object CodecApi21 {
    fun requestCbr(codec: MediaCodec, format: MediaFormat) {
        val caps = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        if (caps.encoderCapabilities.isBitrateModeSupported(
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)) {
            format.setInteger(MediaFormat.KEY_BITRATE_MODE,
                              MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }
    }
}
