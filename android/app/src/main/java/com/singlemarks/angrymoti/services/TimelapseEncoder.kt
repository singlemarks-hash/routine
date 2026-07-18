package com.singlemarks.angrymoti.services

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/**
 * 타임랩스 H.264 인코더 — 프레임(Bitmap)을 받는 즉시 인코딩해 파일 부풀림 없이 진행한다.
 * 입력은 COLOR_FormatYUV420Flexible(소프트웨어 변환)로 넣어 GPU/서피스 의존을 없앴다 —
 * 저가 기기까지 동작이 결정적이다. 재생은 30fps 고정.
 */
class TimelapseEncoder(
    private val outFile: File,
    portrait: Boolean,
    private val watermark: Boolean,
) {
    companion object { const val FPS = 30 }

    private val width = if (portrait) 720 else 1280
    private val height = if (portrait) 1280 else 720

    private val codec: MediaCodec
    private val muxer: MediaMuxer
    private var trackIndex = -1
    private var muxerStarted = false
    private var frameIndex = 0L
    var frameCount = 0; private set

    private val bufferInfo = MediaCodec.BufferInfo()
    private val scaled = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val canvas = Canvas(scaled)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val wmPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; alpha = 200; textSize = height * 0.028f
        setShadowLayer(4f, 0f, 2f, Color.BLACK)
        typeface = android.graphics.Typeface.DEFAULT_BOLD
    }
    private val argb = IntArray(width * height)
    private val yuv = ByteArray(width * height * 3 / 2)

    var firstFrame: Bitmap? = null; private set

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        muxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    /** 프레임 추가 (호출 스레드에서 동기 인코딩 — 캡처 간격이 초 단위라 부담 없음) */
    @Synchronized
    fun addFrame(src: Bitmap) {
        // 중앙 크롭으로 목표 비율에 맞춘다
        val srcRatio = src.width.toFloat() / src.height
        val dstRatio = width.toFloat() / height
        val (cw, ch) = if (srcRatio > dstRatio)
            (src.height * dstRatio).toInt() to src.height
        else
            src.width to (src.width / dstRatio).toInt()
        val cx = (src.width - cw) / 2
        val cy = (src.height - ch) / 2
        canvas.drawBitmap(src, android.graphics.Rect(cx, cy, cx + cw, cy + ch),
            android.graphics.Rect(0, 0, width, height), paint)
        if (watermark) {
            canvas.drawText("AngryMoti", width * 0.04f, height * 0.965f, wmPaint)
        }
        if (firstFrame == null) firstFrame = scaled.copy(Bitmap.Config.ARGB_8888, false)

        scaled.getPixels(argb, 0, width, 0, 0, width, height)
        argbToI420(argb, yuv, width, height)

        val inIndex = codec.dequeueInputBuffer(100_000)
        if (inIndex >= 0) {
            val buf = codec.getInputBuffer(inIndex)!!
            fillFlexible(buf, inIndex)
            val ptsUs = frameIndex * 1_000_000L / FPS
            codec.queueInputBuffer(inIndex, 0, yuvSizeFor(inIndex), ptsUs, 0)
            frameIndex++; frameCount++
        }
        drain(false)
    }

    // Flexible 포맷은 코덱마다 실제 레이아웃이 다르다 — Image API로 plane에 직접 쓴다.
    private fun fillFlexible(fallback: ByteBuffer, inIndex: Int) {
        val image = codec.getInputImage(inIndex)
        if (image != null) {
            val w = width; val h = height
            val yPlane = image.planes[0]; val uPlane = image.planes[1]; val vPlane = image.planes[2]
            var yi = 0
            for (row in 0 until h) {
                val pos = row * yPlane.rowStride
                for (col in 0 until w) yPlane.buffer.put(pos + col * yPlane.pixelStride, yuv[yi++])
            }
            var ui = w * h; var vi = w * h + (w * h / 4)
            for (row in 0 until h / 2) {
                val uPos = row * uPlane.rowStride; val vPos = row * vPlane.rowStride
                for (col in 0 until w / 2) {
                    uPlane.buffer.put(uPos + col * uPlane.pixelStride, yuv[ui++])
                    vPlane.buffer.put(vPos + col * vPlane.pixelStride, yuv[vi++])
                }
            }
        } else {
            fallback.clear(); fallback.put(yuv)
        }
    }

    private fun yuvSizeFor(@Suppress("UNUSED_PARAMETER") inIndex: Int) = yuv.size

    private fun argbToI420(argb: IntArray, out: ByteArray, w: Int, h: Int) {
        var yIdx = 0; var uIdx = w * h; var vIdx = w * h + (w * h / 4)
        for (j in 0 until h) {
            for (i in 0 until w) {
                val p = argb[j * w + i]
                val r = (p shr 16) and 0xFF; val g = (p shr 8) and 0xFF; val b = p and 0xFF
                val y = (66 * r + 129 * g + 25 * b + 128 shr 8) + 16
                out[yIdx++] = y.coerceIn(0, 255).toByte()
                if (j % 2 == 0 && i % 2 == 0) {
                    val u = (-38 * r - 74 * g + 112 * b + 128 shr 8) + 128
                    val v = (112 * r - 94 * g - 18 * b + 128 shr 8) + 128
                    out[uIdx++] = u.coerceIn(0, 255).toByte()
                    out[vIdx++] = v.coerceIn(0, 255).toByte()
                }
            }
        }
    }

    private fun drain(endOfStream: Boolean) {
        if (endOfStream) {
            val inIndex = codec.dequeueInputBuffer(100_000)
            if (inIndex >= 0) codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        }
        while (true) {
            val outIndex = codec.dequeueOutputBuffer(bufferInfo, if (endOfStream) 100_000 else 0)
            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    trackIndex = muxer.addTrack(codec.outputFormat)
                    muxer.start(); muxerStarted = true
                }
                outIndex >= 0 -> {
                    val encoded = codec.getOutputBuffer(outIndex)!!
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) bufferInfo.size = 0
                    if (bufferInfo.size > 0 && muxerStarted) {
                        encoded.position(bufferInfo.offset)
                        encoded.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(trackIndex, encoded, bufferInfo)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    /** 인코딩 종료 — 프레임이 1장도 없으면 파일을 지우고 false */
    @Synchronized
    fun finish(): Boolean {
        return try {
            if (frameCount > 0) drain(true)
            runCatching { codec.stop() }; codec.release()
            if (muxerStarted) { runCatching { muxer.stop() }; }
            muxer.release()
            if (frameCount == 0) { outFile.delete(); false } else true
        } catch (_: Exception) {
            runCatching { muxer.release() }
            outFile.delete(); false
        }
    }
}
