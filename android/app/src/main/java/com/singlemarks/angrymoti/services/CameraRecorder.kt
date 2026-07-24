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
    // 촬영 프레임을 화면과 같은 방향으로 세우기 위한 목표 회전값 — 가로 촬영 시 UI가 실제 디스플레이 회전을 넣어준다.
    // 바인딩 전에 값이 들어오면 저장해 두었다가 바인딩 직후 적용한다(레이스 방지).
    @Volatile private var pendingTargetRotation: Int? = null

    @Volatile private var isRecording = false
    @Volatile private var isPaused = false
    private var encoder: TimelapseEncoder? = null
    private var captureIntervalMs = 1000L
    private var lastCaptureAt = 0L
    // 마지막으로 프레임이 '실제로 인코딩된' 시각 — 촬영 정지 감지의 기준.
    // 시작 시각을 앵커로 두어 카메라가 아예 첫 프레임을 못 주는 경우도 정지로 잡힌다.
    @Volatile private var lastFrameAt = 0L
    // 마지막으로 프레임이 '도착한' 시각 — 일시정지로 버려지는 프레임도 포함(카메라 생존 신호).
    // lastFrameAt(인코딩 성공)과 달리, 통화·백그라운드로 카메라가 끊기면 이 값이 멈춘다.
    @Volatile private var lastFrameArrivedAt = 0L
    private var sessionId: String = ""

    // 사람 부재 감지 — 5초에 1회만 ML Kit 실행 (배터리·발열 최소화)
    private const val PRESENCE_CHECK_MS = 5000L
    // @Volatile — resume()(main)와 onFrame(analysisExecutor)에서 함께 접근하므로 가시성 보장. [P3-5]
    @Volatile private var lastPresenceCheckAt = 0L
    @Volatile private var absenceStartedAt = 0L
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
                pendingTargetRotation?.let { analysis.targetRotation = it }   // 가로 회전 요청이 먼저 왔으면 반영
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

    /**
     * 분석(=녹화) 프레임의 목표 회전을 화면 방향에 맞춘다.
     * 이 값이 곧 proxy.imageInfo.rotationDegrees의 기준이 되어, 가로 촬영 시 프레임이
     * 세로가 아니라 가로(16:9)로 바로 서서 인코딩된다. UI가 실제 디스플레이 회전값(Surface.ROTATION_*)을 넣어준다.
     */
    fun setAnalysisRotation(surfaceRotation: Int) {
        pendingTargetRotation = surfaceRotation
        analysisUseCase?.targetRotation = surfaceRotation
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
        // 카메라가 지금도 프레임을 주고 있는지 (통화·백그라운드로 끊기면 pause와 무관하게 끊긴다).
        // 살아 있으면 재바인딩하지 않아 불필요한 프리뷰 깜빡임이 없다.
        val cameraDelivering = lastFrameArrivedAt != 0L &&
            System.currentTimeMillis() - lastFrameArrivedAt < 3_000L
        // 중단 동안 감지가 멈춰 부재 시간이 묵는다 — 재개 직후 오탐을 막기 위해 초기화
        absenceStartedAt = 0
        lastPresenceCheckAt = 0
        absentSeconds.value = 0
        lastFrameAt = System.currentTimeMillis()   // 재개 직후 정지 오탐 방지
        isPaused = false
        // 통화 등으로 카메라가 끊겨 있었다면 같은 유스케이스로 재바인딩해 프레임을 되살린다.
        // (CameraX 자동 복구가 안 된 케이스 대비 — iOS의 세션 startRunning 복구와 동일 취지)
        if (!cameraDelivering) reassertCameraBinding()
    }

    /** 통화(VoIP)·백그라운드로 카메라가 닫힌 뒤 CameraX가 자동 복구하지 못한 경우,
     *  저장된 프로바이더/유스케이스로 다시 바인딩해 프레임 전달을 되살린다. 인코더는 그대로 이어진다. */
    private fun reassertCameraBinding() {
        val p = provider ?: return
        val analysis = analysisUseCase ?: return
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                camLifecycle.registry.currentState = Lifecycle.State.RESUMED
                p.unbindAll()
                p.bindToLifecycle(
                    camLifecycle,
                    if (frontFacing) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA,
                    previewUseCase, analysis,
                )
                bound = true
                android.util.Log.i("AngryMoti", "resume: 카메라 재바인딩 (통화 등 인터럽트 복구)")
            } catch (e: Exception) {
                bound = false
                android.util.Log.e("AngryMoti", "resume: 카메라 재바인딩 실패", e)
            }
        }
    }

    /** 실촬영 시간(초) ≈ 캡처 프레임 수 × 캡처 간격. 세션엔진의 조기 감지가 경과 시간과 비교한다. */
    val capturedSeconds: Int get() = ((frameCount.value * captureIntervalMs) / 1000L).toInt()

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
        // 카메라 생존 신호 — 일시정지로 프레임을 버리더라도 '도착'은 기록한다.
        // (통화·백그라운드로 카메라가 끊기면 이 값이 멈춰, 재개 시 재바인딩 필요를 판별한다)
        lastFrameArrivedAt = System.currentTimeMillis()
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

        // 타임랩스 프레임 — 회전·인코딩은 전용 스레드에서.
        // iOS 표준을 따라 '저장 영상은 미러링하지 않는다'(실제 방향 보존) — 전면 좌우반전을 굽지 않는다.
        if (captureDue) {
            lastCaptureAt = now
            encodeExecutor.execute {
                val bitmap = if (rotation != 0) {
                    val m = android.graphics.Matrix().apply { postRotate(rotation.toFloat()) }
                    Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
                } else raw
                encoder?.let { e ->
                    val before = e.frameCount
                    runCatching { e.addFrame(bitmap) }
                        .onFailure { android.util.Log.e("AngryMoti", "addFrame failed", it) }
                    frameCount.value = e.frameCount
                    // 프레임이 실제로 인코딩됐을 때만 정지 감지 기준 시각을 갱신한다.
                    // 인코더가 막히거나(버퍼 busy) 실패하면 lastFrameAt이 멈춰 isCaptureStalled()가
                    // 정상 작동 → #12의 '카메라 장애=무효' 경로가 동작한다 (iOS는 성공 append에서만 갱신).
                    if (e.frameCount > before) lastFrameAt = System.currentTimeMillis()
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
