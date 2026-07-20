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
    /** 이번 세션의 촬영 방향 — 세션 화면이 이 값으로 화면 회전을 잠근다 */
    val portraitSession = MutableStateFlow(true)
    val previewUseCase = Preview.Builder().build()   // PreviewView가 화면에서 SurfaceProvider만 붙인다

    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val encodeExecutor = Executors.newSingleThreadExecutor()

    private var provider: ProcessCameraProvider? = null
    private var analysisUseCase: ImageAnalysis? = null
    private var bound = false
    @Volatile private var frontFacing = true

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
            analysisUseCase = analysis
            ContextCompat.getMainExecutor(context).execute {
                camLifecycle.registry.currentState = Lifecycle.State.RESUMED
                p.unbindAll()
                frontFacing = true
                p.bindToLifecycle(camLifecycle, CameraSelector.DEFAULT_FRONT_CAMERA, previewUseCase, analysis)
                bound = true
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** 전/후면 카메라 전환 — 프리뷰·분석 유스케이스를 유지한 채 재바인딩 */
    fun flipCamera(context: Context) {
        val p = provider ?: return
        val analysis = analysisUseCase ?: return
        ContextCompat.getMainExecutor(context).execute {
            frontFacing = !frontFacing
            p.unbindAll()
            p.bindToLifecycle(
                camLifecycle,
                if (frontFacing) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA,
                previewUseCase, analysis,
            )
        }
    }

    /** 촬영 시작 — 세션 길이에 맞춰 캡처 간격을 동적으로 정한다 (재생 30fps) */
    fun startRecording(context: Context, sessionId: String, portrait: Boolean, plannedSeconds: Double, watermark: Boolean) {
        this.sessionId = sessionId
        this.portrait = portrait
        portraitSession.value = portrait
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

    // 핵심 원칙: 카메라 버퍼(ImageProxy)는 절대 붙잡지 않는다.
    // 필요한 프레임만 비트맵으로 즉시 복사하고 바로 close — 프리뷰가 항상 매끄럽고,
    // 얼굴 인식·회전·인코딩 같은 무거운 일은 전부 파이프라인 밖(별도 스레드/비동기)에서 한다.
    // "촬영은 정상, 결과물만 타임랩스"가 되는 구조.
    private fun onFrame(context: Context, proxy: ImageProxy) {
        if (!isRecording || isPaused) { proxy.close(); return }
        val now = System.currentTimeMillis()
        val captureDue = now - lastCaptureAt >= captureIntervalMs
        val presenceDue = now - lastPresenceCheckAt >= PRESENCE_CHECK_MS && !presenceBusy

        if (!captureDue && !presenceDue) { proxy.close(); return }

        // 한 번만 복사하고 즉시 반납 (분석 해상도라 복사 비용은 밀리초 수준)
        val raw: Bitmap? = runCatching { proxy.toBitmap() }.getOrNull()
        val rotation = proxy.imageInfo.rotationDegrees
        proxy.close()
        if (raw == null) return

        // 부재 감지 — 복사본 기반 비동기, 파이프라인과 완전 분리
        if (presenceDue) {
            lastPresenceCheckAt = now
            presenceBusy = true
            faceDetector.process(InputImage.fromBitmap(raw, rotation))
                .addOnSuccessListener { faces ->
                    if (faces.isEmpty()) {
                        if (absenceStartedAt == 0L) absenceStartedAt = now
                        absentSeconds.value = ((now - absenceStartedAt) / 1000).toInt()
                    } else {
                        absenceStartedAt = 0
                        if (absentSeconds.value != 0) absentSeconds.value = 0
                    }
                }
                .addOnCompleteListener { presenceBusy = false }
        }

        // 타임랩스 프레임 — 회전·미러·인코딩은 전용 스레드에서
        if (captureDue) {
            lastCaptureAt = now
            encodeExecutor.execute {
                val mirror = frontFacing
                val bitmap = if (rotation != 0 || mirror) {
                    val m = android.graphics.Matrix().apply {
                        postRotate(rotation.toFloat())
                        if (mirror) postScale(-1f, 1f)   // 전면 카메라만 미러 보정
                    }
                    Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
                } else raw
                encoder?.let { e ->
                    runCatching { e.addFrame(bitmap) }
                    frameCount.value = e.frameCount
                }
            }
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
