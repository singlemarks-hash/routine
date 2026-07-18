package com.singlemarks.angrymoti.services

import android.content.Context
import android.graphics.Bitmap
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.util.concurrent.Executors

/**
 * 전면 카메라 타임랩스 레코더 — iOS CameraRecorder 대응.
 * 화면(거치 가이드→세션)이 바뀌어도 카메라를 재연결하지 않도록,
 * 자체 Lifecycle을 가진 싱글톤으로 앱 수명과 무관하게 1회만 바인딩한다.
 */
object CameraRecorder {
    data class RecordingResult(
        val videoFileName: String,
        val thumbnailFileName: String?,
        val recordedSeconds: Int,
    )

    val frameCount = MutableStateFlow(0)
    val absentSeconds = MutableStateFlow(0)
    val previewUseCase = Preview.Builder().build()   // PreviewView가 화면에서 SurfaceProvider만 붙인다

    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val encodeExecutor = Executors.newSingleThreadExecutor()

    private var provider: ProcessCameraProvider? = null
    private var bound = false

    @Volatile private var isRecording = false
    @Volatile private var isPaused = false
    private var encoder: TimelapseEncoder? = null
    private var captureIntervalMs = 1000L
    private var lastCaptureAt = 0L
    private var sessionId: String = ""
    private var portrait = true

    // 사람 부재 감지 — 5초에 1회만 ML Kit 실행 (배터리·발열 최소화)
    private const val PRESENCE_CHECK_MS = 5000L
    private var lastPresenceCheckAt = 0L
    private var absenceStartedAt = 0L
    private var presenceBusy = false
    private val faceDetector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setMinFaceSize(0.1f)
                .build()
        )
    }

    /** 카메라 전용 lifecycle — startPreview~releaseCamera 사이 RESUMED 유지 */
    private val camLifecycle = object : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    fun sessionDir(context: Context): File =
        File(context.filesDir, "Sessions").apply { mkdirs() }

    /** 거치 가이드 진입 시 1회 — 프리뷰+분석 파이프라인 시작 */
    fun startPreview(context: Context) {
        if (bound) return
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val p = future.get()
            provider = p
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(analysisExecutor) { proxy -> onFrame(context, proxy) }
            ContextCompat.getMainExecutor(context).execute {
                camLifecycle.registry.currentState = Lifecycle.State.RESUMED
                p.unbindAll()
                p.bindToLifecycle(camLifecycle, CameraSelector.DEFAULT_FRONT_CAMERA, previewUseCase, analysis)
                bound = true
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** 촬영 시작 — 세션 길이에 맞춰 캡처 간격을 동적으로 정한다 (재생 30fps) */
    fun startRecording(context: Context, sessionId: String, portrait: Boolean, plannedSeconds: Double, watermark: Boolean) {
        this.sessionId = sessionId
        this.portrait = portrait
        val outMinutes = plannedSeconds / 60.0
        val outSeconds = outMinutes.coerceIn(15.0, 60.0)      // 결과 영상 길이 앵커: 15초~60초
        val targetFrames = (outSeconds * TimelapseEncoder.FPS).coerceAtLeast(1.0)
        captureIntervalMs = ((plannedSeconds / targetFrames) * 1000).toLong()
            .coerceAtLeast(1000L / TimelapseEncoder.FPS)
        val file = File(sessionDir(context), "$sessionId.mp4")
        encoder = TimelapseEncoder(file, portrait, watermark)
        frameCount.value = 0
        absentSeconds.value = 0
        absenceStartedAt = 0; lastPresenceCheckAt = 0; lastCaptureAt = 0
        isPaused = false
        isRecording = true
    }

    fun pause() { isPaused = true }

    fun resume() {
        // 중단 동안 감지가 멈춰 부재 시간이 묵는다 — 재개 직후 오탐을 막기 위해 초기화
        absenceStartedAt = 0
        lastPresenceCheckAt = 0
        absentSeconds.value = 0
        isPaused = false
    }

    @androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
    private fun onFrame(context: Context, proxy: ImageProxy) {
        if (!isRecording || isPaused) { proxy.close(); return }
        val now = System.currentTimeMillis()

        // 부재 감지 (5초 주기)
        if (now - lastPresenceCheckAt >= PRESENCE_CHECK_MS && !presenceBusy) {
            lastPresenceCheckAt = now
            presenceBusy = true
            val media = proxy.image
            if (media != null) {
                val input = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
                faceDetector.process(input)
                    .addOnSuccessListener { faces ->
                        if (faces.isEmpty()) {
                            if (absenceStartedAt == 0L) absenceStartedAt = now
                            absentSeconds.value = ((now - absenceStartedAt) / 1000).toInt()
                        } else {
                            absenceStartedAt = 0
                            if (absentSeconds.value != 0) absentSeconds.value = 0
                        }
                    }
                    .addOnCompleteListener {
                        presenceBusy = false
                        captureIfDue(proxy, now)
                    }
                return   // proxy는 captureIfDue에서 close
            }
            presenceBusy = false
        }
        captureIfDue(proxy, now)
    }

    private fun captureIfDue(proxy: ImageProxy, now: Long) {
        if (isRecording && !isPaused && now - lastCaptureAt >= captureIntervalMs) {
            lastCaptureAt = now
            val bitmap: Bitmap? = runCatching {
                val b = proxy.toBitmap()
                val deg = proxy.imageInfo.rotationDegrees
                if (deg != 0) {
                    val m = android.graphics.Matrix().apply {
                        postRotate(deg.toFloat())
                        // 전면 카메라 미러 보정
                        postScale(-1f, 1f)
                    }
                    Bitmap.createBitmap(b, 0, 0, b.width, b.height, m, true)
                } else b
            }.getOrNull()
            proxy.close()
            if (bitmap != null) {
                encodeExecutor.execute {
                    encoder?.let { e ->
                        runCatching { e.addFrame(bitmap) }
                        frameCount.value = e.frameCount
                    }
                }
            }
        } else {
            proxy.close()
        }
    }

    /** 완주 종료 — 영상 확정 */
    fun stopRecording(context: Context): RecordingResult? = stopInternal(context)

    /** 실패/긴급/안전 종료 — 지금까지의 촬영분은 보존 */
    fun stopPreservingFootage(context: Context): RecordingResult? = stopInternal(context)

    private fun stopInternal(context: Context): RecordingResult? {
        if (!isRecording) return null
        isRecording = false
        val e = encoder ?: return null
        encoder = null
        // 인코딩 큐 비우기를 기다렸다가 마무리
        val done = java.util.concurrent.CountDownLatch(1)
        encodeExecutor.execute { done.countDown() }
        runCatching { done.await(5, java.util.concurrent.TimeUnit.SECONDS) }

        val frames = e.frameCount
        val ok = e.finish()
        if (!ok) return null

        var thumbName: String? = null
        e.firstFrame?.let { first ->
            runCatching {
                val tf = File(sessionDir(context), "$sessionId.jpg")
                tf.outputStream().use { first.compress(Bitmap.CompressFormat.JPEG, 85, it) }
                thumbName = tf.name
            }
        }
        return RecordingResult(
            videoFileName = "$sessionId.mp4",
            thumbnailFileName = thumbName,
            recordedSeconds = ((frames * captureIntervalMs) / 1000).toInt(),
        )
    }

    /** 세션 완전 종료 후 카메라 해제 */
    fun releaseCamera(context: Context) {
        ContextCompat.getMainExecutor(context).execute {
            provider?.unbindAll()
            camLifecycle.registry.currentState = Lifecycle.State.CREATED
            bound = false
        }
    }

    fun deleteFiles(context: Context, videoFileName: String?, thumbnailFileName: String?) {
        videoFileName?.let { File(sessionDir(context), it).delete() }
        thumbnailFileName?.let { File(sessionDir(context), it).delete() }
    }
}
