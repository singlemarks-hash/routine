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
    // 마지막으로 프레임이 '실제로 인코딩된' 시각 — 촬영 정지 감지의 기준.
    // 시작 시각을 앵커로 두어 카메라가 아예 첫 프레임을 못 주는 경우도 정지로 잡힌다.
    @Volatile private var lastFrameAt = 0L
    private var sessionId: String = ""
    private var portrait = true

    // 사람 부재 감지 — 5초에 1회만 ML Kit 실행 (배터리·발열 최소화)
    private const val PRESENCE_CHECK_MS = 5000L
    private var lastPresenceCheckAt = 0L
    private var absenceStartedAt = 0L
    private var presenceBusy = false
    // 얼굴 감지 — ACCURATE 모드 + 최소 크기 완화: 옆얼굴·부분 얼굴도 최대한 잡는다
    // (검사가 5초에 1회뿐이라 정확 모드의 비용 부담 없음)
    private val faceDetector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setMinFaceSize(0.05f)
                .build()
        )
    }

    // 2차 판정: 몸(포즈) 감지 — 고개를 숙이거나 얼굴이 프레임 밖이어도 상반신이 보이면 재석.
    // '얼굴이 안 보인다'가 아니라 '자리에 사람이 없다'만 부재로 판정한다 (iOS 상반신 기준과 통일)
    private val poseDetector by lazy {
        com.google.mlkit.vision.pose.PoseDetection.getClient(
            com.google.mlkit.vision.pose.defaults.PoseDetectorOptions.Builder()
                .setDetectorMode(
                    com.google.mlkit.vision.pose.defaults.PoseDetectorOptions.STREAM_MODE)
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
        // 카메라 권한이 없으면 바인딩이 조용히 실패한다 — 명시적으로 로그를 남긴다
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA)
            != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            android.util.Log.e("AngryMoti", "startPreview: CAMERA 권한 없음 — 프리뷰 시작 불가")
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val p = future.get()
                provider = p
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(analysisExecutor) { proxy -> onFrame(context, proxy) }
                analysisUseCase = analysis
                ContextCompat.getMainExecutor(context).execute {
                    try {
                        camLifecycle.registry.currentState = Lifecycle.State.RESUMED
                        p.unbindAll()
                        frontFacing = true
                        p.bindToLifecycle(camLifecycle, CameraSelector.DEFAULT_FRONT_CAMERA,
                            previewUseCase, analysis)
                        bound = true
                        android.util.Log.i("AngryMoti", "startPreview: 카메라 바인딩 성공")
                    } catch (e: Exception) {
                        // 잠금 상태에서 열거나 다른 앱이 카메라 점유 중이면 여기서 실패한다
                        bound = false
                        android.util.Log.e("AngryMoti", "startPreview: bindToLifecycle 실패", e)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("AngryMoti", "startPreview: provider 획득 실패", e)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** 바인딩이 아직 안 됐으면 다시 시도 — 잠금 해제 직후 등에서 프리뷰를 살리는 재시도 경로 */
    fun retryPreviewIfNeeded(context: Context) {
        if (!bound) startPreview(context)
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

    // 타임랩스 결과 길이 앵커 (촬영 분 → 결과 초) — iOS lengthAnchors와 1:1.
    // 10분→10초, 2시간→40초, 4시간→50초, 8시간→60초. 사이는 선형 보간.
    private val lengthAnchors = listOf(10.0 to 10.0, 120.0 to 40.0, 240.0 to 50.0, 480.0 to 60.0)

    private fun targetOutputSeconds(plannedSeconds: Double): Double {
        val minutes = plannedSeconds / 60.0
        val first = lengthAnchors.first(); val last = lengthAnchors.last()
        if (minutes <= first.first) return first.second
        if (minutes >= last.first) return last.second
        for (i in 1 until lengthAnchors.size) {
            val a = lengthAnchors[i - 1]; val b = lengthAnchors[i]
            if (minutes <= b.first) {
                val t = (minutes - a.first) / (b.first - a.first)
                return a.second + (b.second - a.second) * t
            }
        }
        return last.second
    }

    /** 촬영 시작 — 세션 길이에 맞춰 캡처 간격을 동적으로 정한다 (재생 30fps) */
    fun startRecording(context: Context, sessionId: String, portrait: Boolean, plannedSeconds: Double, watermark: Boolean) {
        this.sessionId = sessionId
        this.portrait = portrait
        portraitSession.value = portrait
        // iOS와 동일한 앵커 보간으로 결과 길이 산출 (10분→10초 …)
        val outSeconds = targetOutputSeconds(plannedSeconds)
        val targetFrames = (outSeconds * TimelapseEncoder.FPS).coerceAtLeast(1.0)
        captureIntervalMs = ((plannedSeconds / targetFrames) * 1000).toLong()
            .coerceAtLeast(1000L / TimelapseEncoder.FPS)
        val file = File(sessionDir(context), "$sessionId.mp4")
        encoder = TimelapseEncoder(file, portrait, watermark)
        frameCount.value = 0
        absentSeconds.value = 0
        absenceStartedAt = 0; lastPresenceCheckAt = 0; lastCaptureAt = 0
        lastFrameAt = System.currentTimeMillis()   // 정지 감지 앵커 — 첫 프레임 미도착도 잡는다
        isPaused = false
        isRecording = true
    }

    fun pause() { isPaused = true }

    fun resume() {
        // 중단 동안 감지가 멈춰 부재 시간이 묵는다 — 재개 직후 오탐을 막기 위해 초기화
        absenceStartedAt = 0
        lastPresenceCheckAt = 0
        absentSeconds.value = 0
        lastFrameAt = System.currentTimeMillis()   // 재개 직후 정지 오탐 방지
        isPaused = false
    }

    /** 촬영 신호 정지 감지 — 프레임이 (캡처 간격×3, 최소 15초)를 넘게 안 들어오면 정지로 본다.
     *  카메라 미개시·세션 인터럽션·인코딩 저장 실패를 공통으로 잡는다. 일시정지 중엔 false. */
    fun isCaptureStalled(): Boolean {
        if (!isRecording || isPaused || lastFrameAt == 0L) return false
        return System.currentTimeMillis() - lastFrameAt > maxOf(captureIntervalMs * 3, 15_000L)
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
        val raw: Bitmap? = toBitmapSafe(proxy)
        val rotation = proxy.imageInfo.rotationDegrees
        proxy.close()
        if (raw == null) return

        // 부재 감지 — 복사본 기반 비동기, 파이프라인과 완전 분리.
        // 기준은 '사람의 몸': 1차 얼굴 / 2차 몸(포즈). 포즈는 뒷모습·고개 숙임도 잡는다.
        // 움직임은 재석 근거로 쓰지 않는다 — 흔들리는 장난감·커튼이 빈자리를 재석으로 못 만들고,
        // 미동 없이 몰입한 사람은 몸이 보이는 한 재석이다.
        if (presenceDue) {
            lastPresenceCheckAt = now
            presenceBusy = true
            val image = InputImage.fromBitmap(raw, rotation)
            fun markPresent() {
                absenceStartedAt = 0
                if (absentSeconds.value != 0) absentSeconds.value = 0
            }
            fun markAbsent() {
                if (absenceStartedAt == 0L) absenceStartedAt = now
                absentSeconds.value = ((now - absenceStartedAt) / 1000).toInt()
            }
            faceDetector.process(image)
                .addOnSuccessListener { faces ->
                    if (faces.isNotEmpty()) {
                        markPresent(); presenceBusy = false
                    } else {
                        poseDetector.process(image)
                            .addOnSuccessListener { pose ->
                                val bodyVisible = pose.allPoseLandmarks
                                    .count { it.inFrameLikelihood > 0.5f } >= 4
                                if (bodyVisible) markPresent() else markAbsent()
                            }
                            .addOnFailureListener { markAbsent() }
                            .addOnCompleteListener { presenceBusy = false }
                    }
                }
                .addOnFailureListener { presenceBusy = false }
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
                        .onFailure { android.util.Log.e("AngryMoti", "addFrame failed", it) }
                    frameCount.value = e.frameCount
                    lastFrameAt = System.currentTimeMillis()   // 실제 인코딩된 시각 갱신
                }
            }
        }
    }

    /** 프레임 → Bitmap. CameraX 네이티브(toBitmap)가 실패하는 기기(일부 에뮬레이터 등)에선
     *  순수 코틀린 경로(YUV→NV21→JPEG→Bitmap)로 폴백한다 — 네이티브 라이브러리 불필요. */
    private fun toBitmapSafe(proxy: ImageProxy): Bitmap? =
        runCatching { proxy.toBitmap() }.getOrNull()
            ?: runCatching {
                val nv21 = yuv420ToNv21(proxy)
                val yuvImage = android.graphics.YuvImage(
                    nv21, android.graphics.ImageFormat.NV21, proxy.width, proxy.height, null)
                val out = java.io.ByteArrayOutputStream()
                yuvImage.compressToJpeg(android.graphics.Rect(0, 0, proxy.width, proxy.height), 88, out)
                val bytes = out.toByteArray()
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }.onFailure { android.util.Log.e("AngryMoti", "toBitmapSafe fallback failed", it) }
                .getOrNull()

    private fun yuv420ToNv21(image: ImageProxy): ByteArray {
        val w = image.width; val h = image.height
        val out = ByteArray(w * h * 3 / 2)
        val y = image.planes[0]
        var pos = 0
        for (row in 0 until h) {
            val base = row * y.rowStride
            for (col in 0 until w) out[pos++] = y.buffer.get(base + col * y.pixelStride)
        }
        val u = image.planes[1]; val v = image.planes[2]
        for (row in 0 until h / 2) {
            val uBase = row * u.rowStride; val vBase = row * v.rowStride
            for (col in 0 until w / 2) {
                out[pos++] = v.buffer.get(vBase + col * v.pixelStride)
                out[pos++] = u.buffer.get(uBase + col * u.pixelStride)
            }
        }
        return out
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
        android.util.Log.i("AngryMoti", "stopRecording frames=$frames ok=$ok")
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
