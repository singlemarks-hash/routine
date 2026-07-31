//
//  CameraRecorder.swift
//  TimeLock
//
//  전면 카메라에서 프레임을 뽑아 온디바이스 HEVC 타임랩스로 인코딩한다.
//  캡처 간격은 세션 길이에 맞춰 시작 시 동적으로 정한다(아이폰 기본 타임랩스처럼
//  결과 길이 앵커: 10분→10초, 2시간→40초, 4시간→50초, 8시간→60초.
//  파일은 Documents/Sessions/에 완전 보호(FileProtection.complete)로 저장한다.
//
//  방향 처리: 카메라 버퍼는 항상 네이티브 가로(1280×720)로 받고, 세로 영상은
//  픽셀을 회전시키는 대신 AVAssetWriterInput.transform 메타데이터로 세운다.
//  → 버퍼 크기와 저장 규격이 항상 일치하므로 영상이 늘어나지 않는다.
//  촬영 방향은 시작 시 SessionOrientation으로 확정되며 도중에 바뀌지 않는다.
//

import Foundation
import AVFoundation
import UIKit
import Vision

final class CameraRecorder: NSObject, ObservableObject {
    static let shared = CameraRecorder()

    @Published var isAuthorized = false
    @Published private(set) var frameCount: Int = 0
    /// 마지막으로 프레임이 '실제로 인코딩된' 시각 — 촬영 정지 감지의 기준(SessionEngine이 사용).
    /// 시작 시각을 앵커로 두어 카메라가 첫 프레임을 못 주는 경우도 정지로 잡힌다.
    @Published private(set) var lastFrameAt: Date = .distantPast
    /// 현재 카메라 (기본 전면 — selfie 카드의 전환 버튼으로 변경)
    @Published private(set) var position: AVCaptureDevice.Position = .front

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    /// 촬영 시작 시 확정되는 세션 방향 (UI 잠금용)
    private var sessionOrientation: SessionOrientation = .portrait
    /// 카메라·기기 방향에 맞는 회전각을 자동 산출 (전/후면 센서 차이까지 처리)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let processingQueue = DispatchQueue(label: "timelock.camera.frames")

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var isPaused = false
    private var lastCaptureAt: TimeInterval = 0
    private var outputURL: URL?
    private var thumbnailImage: UIImage?
    private var pixelSize: CGSize = .zero

    // MARK: 세그먼트 녹화 (긴급 용무·백그라운드를 건너 촬영을 잇는 구조)
    //
    // iOS는 앱이 백그라운드로 가는 순간 하드웨어 HEVC 인코더 세션을 무효화한다.
    // 한 번 .failed가 된 AVAssetWriter는 되살릴 방법이 없어서, 세션당 writer 1개
    // 구조에서는 통화/앱 전환 뒤 재촬영해도 인코딩이 조용히 전부 실패했다
    // (프리뷰는 살아 있어 겉으론 촬영 중처럼 보임 → 스톨 오탐 → 긴급용무 무한 반복
    // → 종료 시 writer.failed로 영상 전량 폐기 → 안전 종료. 실기기 신고 유형).
    //
    // 해법: 중단(pause)마다 현재 writer를 세그먼트 파일로 즉시 확정하고, 재개 후
    // 첫 프레임에서 새 writer/새 세그먼트를 연다. 종료 시 세그먼트들을 무재인코딩
    // (passthrough)으로 이어붙여 기존과 동일한 단일 .mov를 만든다 — 긴급용무를
    // 몇 번 쓰든 결과는 하나의 이어진 타임랩스다. 부수 효과로, 통화 중 앱이 죽어도
    // 이미 확정된 세그먼트(moov 기록 완료)는 살아남는다.
    private struct Segment {
        let url: URL
        var frames: Int
    }
    /// 확정됐거나 확정 중(finishWriting 진행 중)인 세그먼트들. processingQueue에서만 접근.
    private var segments: [Segment] = []
    private var segmentIndex = 0
    /// 현재 세그먼트 안에서의 프레임 번호 — writer마다 0부터 시작해야 병합 시 공백이 없다.
    private var segmentFrameCount = 0
    private var currentSegmentURL: URL?
    /// 진행 중인 finishWriting들의 완료 대기용 (stopRecording이 병합 전에 기다린다)
    private let finishGroup = DispatchGroup()
    /// 세그먼트 선제 교체 주기 — 중단 없이 오래 달려도 세그먼트 하나가 이 길이를 넘지
    /// 않게 잘라 둔다. writer가 급사(메모리 압박 등)하면 백스톱이 현재 세그먼트를
    /// 통째로 버리는데, 로테이션이 없으면 8시간 무중단 세션에서 그 '하나'가 수 시간
    /// 분량일 수 있다 — 최악 유실을 이 주기로 묶는다.
    private let segmentRotationInterval: TimeInterval = 600
    /// 현재 세그먼트가 열린 시각 (CACurrentMediaTime 기준, processingQueue에서 접근)
    private var segmentStartedAt: TimeInterval = 0

    /// 타임랩스 캡처 간격 — 세션 길이에 맞춰 startRecording에서 동적으로 정한다.
    /// (짧은 세션은 촘촘히, 긴 세션은 성기게 캡처해 결과 길이를 20~40초로 수렴)
    private var captureInterval: TimeInterval = 1.0

    // MARK: 사람 부재 감지 (온디바이스 Vision — 외부 의존성·네트워크 없음)
    /// 연속 부재 시간(초). 사람이 다시 잡히면 0으로 리셋. SessionEngine이 정책 판정에 사용.
    @Published private(set) var absentSeconds: Int = 0
    private var absenceStartedAt: TimeInterval?
    private var lastPresenceCheckAt: TimeInterval = 0
    /// 감지 주기 — 평상시 5초에 1회만 Vision을 돌려 배터리·발열 영향 최소화 (프레임당 아님).
    /// 기기가 뜨거워지면(systemPressure) 간격을 늘려 부하를 덜어 준다 — 발열이 심해지면
    /// iOS가 캡처 세션을 통째로 중단시키고, 그게 '프레임 정지'로 보여 긴급용무 오진입이 된다.
    private var presenceCheckInterval: TimeInterval {
        switch systemPressureLevel {
        case .serious:  return 10
        case .critical, .shutdown: return 20
        default:        return 5
        }
    }
    /// 현재 기기 열/전력 압력 단계 — 카메라 부하 조절과 인터럽션 사유 판정에 쓴다.
    @Published private(set) var systemPressureLevel: AVCaptureDevice.SystemPressureState.Level = .nominal
    private var pressureObservation: NSKeyValueObservation?

    /// 카메라가 '기기 사정'으로 멈춘 상태인가 — 사용자가 앱을 나간 것과 구분한다.
    /// 시스템 압력(발열)·다른 앱의 카메라 점유·미디어 서비스 리셋 등이 여기 해당한다.
    /// 이때의 프레임 정지는 사용자 잘못이 아니므로 벌점 없이 유예로 처리해야 한다.
    @Published private(set) var isInterruptedBySystem = false
    /// 마지막으로 기기 사정 인터럽션이 있었던 시각.
    /// 정지 한계(30초)에 못 미치는 짧은 중단이 반복되면 촬영량만 조용히 뒤처지는데,
    /// 그 상태로 촬영 건강도를 판정하면 멀쩡한 세션이 '촬영 장애'로 무효 종료된다.
    @Published private(set) var lastSystemInterruptionAt: Date?
    /// 재생 프레임레이트
    private let playbackFPS: Int32 = 30

    // MARK: 타임랩스 길이 설계 (예약 시간별 결과 길이 앵커)
    /// (촬영 분, 결과 초) 앵커 — 이 점들을 정확히 통과하고 사이는 선형 보간.
    /// 10분→10초, 2시간→40초, 4시간→50초, 8시간→60초.
    private let lengthAnchors: [(minutes: Double, output: Double)] = [
        (10, 10), (120, 40), (240, 50), (480, 60)
    ]

    /// 순수 촬영 시간(초) ≈ 캡처한 프레임 수 × 캡처 간격.
    /// 일시정지 중엔 프레임을 버리므로 자연히 촬영 시간에서 제외된다.
    var capturedSeconds: Int { Int((Double(frameCount) * captureInterval).rounded()) }

    /// 촬영 정지 판정 기준 시간 — 이 시간 넘게 새 프레임이 없으면 정지로 본다.
    /// 캡처 간격의 3배 또는 최소 30초. (긴 세션은 캡처 간격이 커 그만큼 여유를 준다)
    ///
    /// 30초로 넉넉히 잡아도 회피 구멍이 되지 않는다 — 실제 이탈(앱 백그라운드·화면 잠금)은
    /// ScenePhase/protectedData가 즉시 잡으므로, 이 정지 감지는 그 둘이 못 보는 상황
    /// (카메라만 멈춤)을 위한 보조 장치다. 반대로 짧게 잡으면 발열로 잠깐 끊긴 것까지
    /// 이탈로 오판해 촬영 중인 사용자를 긴급용무로 밀어낸다.
    var captureStallLimit: TimeInterval { max(captureInterval * 3, 30) }

    /// 세션 길이(초)에 맞는 최종 타임랩스 목표 길이(초)를 앵커 구간 선형 보간으로 산출.
    /// 앵커를 정확히 통과하고, 그 사이는 부드러운 직선으로 이어 각 옵션이 고유 길이를 갖는다.
    private func targetOutputSeconds(forPlanned planned: Double) -> Double {
        let minutes = planned / 60
        guard let first = lengthAnchors.first, let last = lengthAnchors.last else { return 30 }
        if minutes <= first.minutes { return first.output }
        if minutes >= last.minutes { return last.output }
        for i in 1..<lengthAnchors.count {
            let a = lengthAnchors[i - 1], b = lengthAnchors[i]
            if minutes <= b.minutes {
                let t = (minutes - a.minutes) / (b.minutes - a.minutes)
                return a.output + (b.output - a.output) * t
            }
        }
        return last.output
    }

    /// 세션 시작 시 캡처 간격을 계산한다.
    /// 결과 프레임 수 = 목표길이 × 재생fps, 캡처 간격 = 실제 촬영시간 ÷ 결과 프레임 수.
    private func recomputeCaptureInterval(plannedSeconds planned: Double) {
        let planned = max(planned, 1)
        let outSeconds = targetOutputSeconds(forPlanned: planned)
        let targetFrames = max(1, outSeconds * Double(playbackFPS))
        // 카메라가 초당 30프레임을 주므로 그보다 촘촘히는 못 캡처한다(하한 1/30초).
        captureInterval = max(1.0 / Double(playbackFPS), planned / targetFrames)
    }

    // MARK: 세션 인터럽트 복구 (VoIP 통화·타앱 카메라 점유 등)

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionWasInterrupted),
                       name: .AVCaptureSessionWasInterrupted, object: captureSession)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded),
                       name: .AVCaptureSessionInterruptionEnded, object: captureSession)
        nc.addObserver(self, selector: #selector(sessionRuntimeError),
                       name: .AVCaptureSessionRuntimeError, object: captureSession)
    }

    /// 캡처 세션이 중단됐다 — **사유를 봐야 한다**.
    ///
    /// 프레임이 끊겼다는 결과만 보면 '사용자가 앱을 나갔다'와 '기기가 카메라를 멈췄다'를
    /// 구분할 수 없다. iOS는 그 사유를 여기서 알려주므로, 기기 사정(발열로 인한 시스템
    /// 압력·다른 앱의 카메라 점유 등)이면 표시만 해두고 SessionEngine이 벌점 없이
    /// 유예 처리하게 한다. 사용자 행위(백그라운드 전환)는 ScenePhase가 따로 잡는다.
    @objc private func sessionWasInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        // 백그라운드 전환만 '사용자 행위'다 — 그건 ScenePhase가 이미 이탈로 판정하므로
        // 여기서 기기 사정으로 표시하면 벌점을 피하는 구멍이 된다. 나머지(발열·타앱
        // 점유·사유 불명)는 사용자가 어쩔 수 없는 상황이라 관대하게 본다.
        let systemCaused = (reason != .videoDeviceNotAvailableInBackground)
        DispatchQueue.main.async {
            self.isInterruptedBySystem = systemCaused
            if systemCaused { self.lastSystemInterruptionAt = Date() }
            // 인터럽션 동안 프레임이 안 오므로 정지 앵커를 밀어 둔다 — 복귀 직후
            // 즉시 스톨로 잡히는 것을 막는다 (재개 시각부터 다시 센다).
            self.lastFrameAt = Date()
        }
    }

    /// 보이스톡(VoIP)·다른 앱의 카메라 점유가 끝나면 iOS가 세션을 자동 재개하지 않을 수 있다.
    /// 이때 세션을 되살리지 않으면, 재촬영을 눌러도 카메라가 죽어 있어 프레임이 안 들어오고
    /// 스톨 → 긴급용무 무한 반복이 된다. 인터럽트 종료 시 세션을 다시 살린다.
    @objc private func sessionInterruptionEnded(_ note: Notification) {
        DispatchQueue.main.async {
            self.isInterruptedBySystem = false
            self.lastFrameAt = Date()   // 재개 직후 정지 오탐 방지
        }
        resumeSessionIfNeeded()
    }

    /// 미디어 서비스 리셋 등 런타임 에러 — Apple 권장대로 세션 재기동을 시도한다.
    @objc private func sessionRuntimeError(_ note: Notification) {
        resumeSessionIfNeeded()
    }

    /// 세션이 멈춰 있으면 백그라운드 큐에서 다시 startRunning (통화·에러 후 복구용, 재호출 안전).
    /// SessionEngine이 스톨을 감지했을 때 '판정 전 1회 복구 시도'로도 부른다.
    func resumeSessionIfNeeded() {
        processingQueue.async { [captureSession] in
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    /// 기기 열/전력 압력 관찰 — 단계가 오르면 Vision 검사 간격이 자동으로 늘어난다.
    /// (압력이 .critical까지 가면 iOS가 캡처를 아예 중단시키므로, 그 전에 부하를 던다)
    private func observeSystemPressure(on device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] dev, _ in
            let level = dev.systemPressureState.level
            DispatchQueue.main.async { self?.systemPressureLevel = level }
        }
    }

    // MARK: 권한 & 세션 구성

    /// 이미 거부(또는 기기 정책으로 제한)된 상태 — 시스템 창이 다시 뜨지 않으므로
    /// 자체 안내로 iOS 설정에 보내야 한다. (iOS는 권한 창을 설치당 1회만 띄운다)
    var isAccessBlocked: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    func requestAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            await MainActor.run { isAuthorized = true }
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run { isAuthorized = granted }
            return granted
        default:
            await MainActor.run { isAuthorized = false }
            return false
        }
    }

    func configureSessionIfNeeded() {
        guard captureSession.inputs.isEmpty else { return }
        captureSession.beginConfiguration()
        // FHD 고정 — 세로 1080×1920 / 가로 1920×1080. 720p 대비 화각도 넓다(x1에 가까움).
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1920x1080)
            ? .hd1920x1080 : .hd1280x720

        guard let input = makeInput(position: position),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)
        currentInput = input
        observeSystemPressure(on: input.device)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.commitConfiguration()
        applyConnectionSettings()
        updateRotationCoordinator()
    }

    private func makeInput(position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            return nil
        }
        return try? AVCaptureDeviceInput(device: device)
    }

    /// 데이터 출력 연결의 미러링만 설정 (회전각은 RotationCoordinator가 담당).
    /// 저장 영상은 미러링하지 않는다(실제 방향 보존). 프리뷰는 레이어가 알아서 미러링.
    private func applyConnectionSettings() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// 현재 카메라에 맞는 RotationCoordinator를 만들고, 산출된 회전각을 데이터 출력에 반영.
    /// 전/후면 센서 방향 차이와 기기 방향을 Apple이 자동 처리 → 어느 카메라든 정립 촬영.
    private func updateRotationCoordinator() {
        guard let device = currentInput?.device else { return }
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyCaptureRotation()
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyCaptureRotation() }
        }
    }

    private func applyCaptureRotation() {
        // 녹화 중에는 각도를 절대 바꾸지 않는다. writer는 첫 프레임 치수로 한 번만 생성되므로,
        // 수평 트래커가 촬영 중 각도를 90°↔0°로 틀면 이후 버퍼 치수가 writer 규격과 어긋나
        // adaptor.append가 계속 실패한다 → lastFrameAt 정지 → 스톨 오탐 → 무음 긴급용무로 오진입.
        // (세션 중엔 화면 방향이 잠겨 있어 각도를 바꿀 이유도 없다.)
        guard !isRecording else { return }
        guard let coordinator = rotationCoordinator,
              let connection = videoOutput.connection(with: .video) else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelCapture
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /// 전/후면 카메라 전환 — 구도 단계에서만 사용 (촬영 방향·해상도는 유지)
    func switchCamera() {
        configureSessionIfNeeded()
        let newPosition: AVCaptureDevice.Position = (position == .front) ? .back : .front
        guard let newInput = makeInput(position: newPosition) else { return }

        captureSession.beginConfiguration()
        if let current = currentInput { captureSession.removeInput(current) }
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
            currentInput = newInput
            position = newPosition
            observeSystemPressure(on: newInput.device)
        } else if let current = currentInput, captureSession.canAddInput(current) {
            captureSession.addInput(current)   // 실패 시 원복
        }
        captureSession.commitConfiguration()
        applyConnectionSettings()
        updateRotationCoordinator()   // 새 카메라 기준으로 회전각 재산출
    }

    func startPreview() {
        configureSessionIfNeeded()
        guard !captureSession.isRunning else { return }
        processingQueue.async { [captureSession] in
            captureSession.startRunning()
        }
    }

    func stopPreview() {
        guard captureSession.isRunning, !isRecording else { return }
        processingQueue.async { [captureSession] in
            captureSession.stopRunning()
        }
    }

    // MARK: 녹화 제어

    /// 촬영 시작. writer는 첫 프레임에서 실제 버퍼 크기를 보고 생성한다(지연 생성).
    /// → 기기가 세로/가로 어느 크기로 버퍼를 주든 규격이 정확히 일치, 늘어남·오차 없음.
    func startRecording(sessionID: UUID, orientation: SessionOrientation,
                        plannedSeconds: Double) throws {
        configureSessionIfNeeded()
        sessionOrientation = orientation
        applyConnectionSettings()
        recomputeCaptureInterval(plannedSeconds: plannedSeconds)

        let fileName = "\(sessionID.uuidString).mov"
        let url = SessionStorage.directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        processingQueue.sync {
            self.writer = nil            // 첫 프레임에서 생성
            self.writerInput = nil
            self.adaptor = nil
            self.outputURL = url         // 최종 병합 파일 — 세그먼트는 "-segN.mov"로 따로
            self.segments = []
            self.segmentIndex = 0
            self.segmentFrameCount = 0
            self.currentSegmentURL = nil
            self.thumbnailImage = nil
            self.lastCaptureAt = 0
            self.frameCountInternal = 0
            self.isPaused = false
            self.isRecording = true
            self.absenceStartedAt = nil
            self.lastPresenceCheckAt = 0
        }
        DispatchQueue.main.async {
            self.frameCount = 0
            self.absentSeconds = 0
            self.lastFrameAt = Date()   // 정지 감지 앵커 — 첫 프레임 미도착도 잡는다
        }
        startPreview()
    }

    /// 새 세그먼트의 writer를 생성한다 — 첫 프레임의 확정된 크기로 (processingQueue에서 호출).
    /// 세그먼트 파일명: "<세션ID>-seg<N>.mov". 종료 시 하나로 병합돼 "<세션ID>.mov"가 된다.
    private func setupWriter(width: Int, height: Int) {
        guard let base = outputURL else { return }
        let segName = base.deletingPathExtension().lastPathComponent + "-seg\(segmentIndex).mov"
        let url = base.deletingLastPathComponent().appendingPathComponent(segName)
        segmentIndex += 1
        segmentFrameCount = 0
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,   // FHD 기준
                    AVVideoExpectedSourceFrameRateKey: playbackFPS
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ])
            guard writer.canAdd(input) else { return }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.writerInput = input
            self.adaptor = adaptor
            self.currentSegmentURL = url
            self.segmentStartedAt = CACurrentMediaTime()
            // 쓰는 중인 파일은 completeUnlessOpen — .complete로 두면 화면 잠금 순간
            // 접근이 박탈돼 인코딩이 그 자리에서 죽는다(두 번째 사망 경로).
            // 최종 병합 파일에는 .complete를 되건다.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        } catch { }
    }

    /// 현재 writer를 세그먼트로 확정한다 (processingQueue에서 호출).
    /// 백그라운드 진입 전에 moov를 기록해 두는 것이 핵심 — 인코더가 무효화돼도
    /// 여기까지의 촬영분은 디스크에 완결된 파일로 남는다.
    private func finalizeCurrentSegmentLocked() {
        guard let w = writer, let input = writerInput, let url = currentSegmentURL else { return }
        segments.append(Segment(url: url, frames: segmentFrameCount))
        let slot = segments.count - 1
        writer = nil; writerInput = nil; adaptor = nil
        currentSegmentURL = nil
        input.markAsFinished()
        let group = finishGroup   // weak self가 죽어도 반드시 leave되도록 직접 캡처
        group.enter()
        w.finishWriting { [weak self] in
            if w.status != .completed {
                // 마감 실패(인코더 이미 사망 등) — 이 세그먼트는 재생 불가이므로 버린다.
                // 이전에 확정된 세그먼트들은 영향 없다.
                try? FileManager.default.removeItem(at: url)
                if let self {
                    self.processingQueue.async {
                        if self.segments.indices.contains(slot) { self.segments[slot].frames = 0 }
                        group.leave()
                    }
                    return
                }
            }
            group.leave()
        }
    }

    /// 일시중단(긴급 용무·이탈) — 프레임 수신을 멈추고 현재 세그먼트를 즉시 확정한다.
    /// 재개 후 첫 프레임이 새 세그먼트를 연다 (죽었을지 모르는 writer를 절대 재사용하지 않는다).
    func pause() {
        processingQueue.async {
            self.isPaused = true
            self.finalizeCurrentSegmentLocked()
        }
    }
    func resume() {
        // 통화(보이스톡)·타앱 카메라 점유로 세션이 죽어 있었다면 먼저 되살린다.
        // (같은 processingQueue라 startRunning이 끝난 뒤 isPaused가 풀린다 → 프레임 유실 없음)
        resumeSessionIfNeeded()
        // 중단 동안 감지가 멈추므로 부재 시간이 묵은 값으로 남아 있다 —
        // 그대로 두면 재개 직후 2분 판정이 곧바로 다시 발동하므로 초기화한다.
        processingQueue.async {
            self.isPaused = false
            self.absenceStartedAt = nil
            self.lastPresenceCheckAt = 0
        }
        DispatchQueue.main.async {
            self.absentSeconds = 0
            self.lastFrameAt = Date()   // 재개 직후 정지 오탐 방지
        }
    }

    struct RecordingResult {
        let videoFileName: String
        let thumbnailFileName: String?
        let frames: Int
        /// 순수 촬영 시간(초) = 프레임 수 × 캡처 간격
        let recordedSeconds: Int
    }

    enum RecorderError: Error { case writerSetupFailed, notRecording }

    /// 녹화 종료. 마지막 세그먼트를 확정하고, 세그먼트 전부를 단일 .mov로 병합해 반환한다.
    /// 긴급 용무로 몇 번을 끊었든 결과는 이어진 타임랩스 하나다.
    func stopRecording() async -> RecordingResult? {
        var localURL: URL?
        var localThumb: UIImage?
        var wasRecording = false

        processingQueue.sync {
            guard isRecording else { return }
            wasRecording = true
            isRecording = false
            finalizeCurrentSegmentLocked()   // 촬영 중이던 마지막 세그먼트 마감
            localURL = outputURL
            localThumb = thumbnailImage
        }
        guard wasRecording, let finalURL = localURL else { return nil }

        // 진행 중인 finishWriting(직전 pause 포함)이 모두 끝나기를 기다린 뒤에 병합한다.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishGroup.notify(queue: .global()) { cont.resume() }
        }
        stopPreview()

        // 확정 완료 후의 최종 세그먼트 상태 — 마감 실패한 세그먼트는 frames=0으로 지워져 있다.
        let validSegments = processingQueue.sync { segments }
            .filter { $0.frames > 0 && FileManager.default.fileExists(atPath: $0.url.path) }
        let frames = validSegments.reduce(0) { $0 + $1.frames }

        // 유효 촬영분이 하나도 없으면 무의미 — 전부 지우고 nil (엔진이 안전 종료로 강등).
        guard frames > 0 else {
            for seg in processingQueue.sync(execute: { segments }) {
                try? FileManager.default.removeItem(at: seg.url)
            }
            try? FileManager.default.removeItem(at: finalURL)
            return nil
        }

        let merged = await Self.mergeSegments(validSegments.map(\.url), into: finalURL)
        if merged {
            for seg in validSegments { try? FileManager.default.removeItem(at: seg.url) }
        } else {
            // 병합 실패 백스톱 — 가장 긴 유효 세그먼트라도 결과로 살린다. 전량 폐기는 없다.
            guard let best = validSegments.max(by: { $0.frames < $1.frames }) else { return nil }
            try? FileManager.default.removeItem(at: finalURL)
            do { try FileManager.default.moveItem(at: best.url, to: finalURL) }
            catch { return nil }
            for seg in validSegments where seg.url != best.url {
                try? FileManager.default.removeItem(at: seg.url)
            }
        }
        // 완성된 파일에는 원래의 완전 보호를 되건다 (쓰는 중이 아니므로 안전).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: finalURL.path)

        var thumbName: String?
        if let thumb = localThumb, let data = thumb.jpegData(compressionQuality: 0.8) {
            let name = finalURL.deletingPathExtension().lastPathComponent + "-thumb.jpg"
            let thumbURL = SessionStorage.directory.appendingPathComponent(name)
            try? data.write(to: thumbURL, options: [.completeFileProtection])
            thumbName = name
        }
        return RecordingResult(videoFileName: finalURL.lastPathComponent,
                               thumbnailFileName: thumbName,
                               frames: frames,
                               recordedSeconds: Int((Double(frames) * captureInterval).rounded()))
    }

    /// 세그먼트들을 재인코딩 없이(passthrough) 시간순으로 이어붙여 최종 파일을 만든다.
    /// 세그먼트가 1개면 export 없이 파일 이동으로 끝낸다 (대부분의 세션이 이 경로).
    private static func mergeSegments(_ urls: [URL], into finalURL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: finalURL)
        if urls.count == 1 {
            do { try FileManager.default.moveItem(at: urls[0], to: finalURL); return true }
            catch { return false }
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await assetTrack.load(.timeRange),
                  range.duration > .zero else { continue }
            do { try track.insertTimeRange(range, of: assetTrack, at: cursor) } catch { continue }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard cursor > .zero, let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else { return false }
        export.outputURL = finalURL
        export.outputFileType = .mov
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed
    }

    /// 세션을 폐기하지 않고 현재까지 촬영분을 보존한 채 중단 (이탈/긴급/안전 종료 공통)
    func stopPreservingFootage() async -> RecordingResult? {
        await stopRecording()
    }

    private var frameCountInternal = 0
}

// MARK: - 프레임 캡처 (1fps 스로틀)

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, !isPaused,
              let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CACurrentMediaTime()

        // 사람 부재 감지 — 타임랩스 캡처 간격과 무관하게 5초마다 확인
        if now - lastPresenceCheckAt >= presenceCheckInterval {
            lastPresenceCheckAt = now
            detectPresence(in: source, at: now)
        }

        guard now - lastCaptureAt >= captureInterval else { return }
        lastCaptureAt = now

        // 버퍼는 연결(RotationCoordinator)이 이미 카메라별로 정립시켜 전달한다.
        let buffer = source

        // 첫 프레임에서 확정된 크기로 writer 생성 (회전 결과에 정확히 맞춤 → 늘어남 없음)
        if writer == nil {
            setupWriter(width: CVPixelBufferGetWidth(buffer),
                        height: CVPixelBufferGetHeight(buffer))
        }
        guard let input = writerInput, let adaptor = adaptor,
              input.isReadyForMoreMediaData else { return }

        // 타임스탬프는 '세그먼트 내' 프레임 번호 — writer마다 0부터. 전역 번호를 쓰면
        // 두 번째 세그먼트가 앞부분이 빈 영상이 되어 병합 결과에 공백이 생긴다.
        let time = CMTime(value: CMTimeValue(segmentFrameCount), timescale: playbackFPS)
        if adaptor.append(buffer, withPresentationTime: time) {
            segmentFrameCount += 1
            frameCountInternal += 1
            let count = frameCountInternal
            if thumbnailImage == nil {
                thumbnailImage = Self.image(from: buffer)   // 이미 정립된 버퍼
            }
            DispatchQueue.main.async {
                self.frameCount = count
                self.lastFrameAt = Date()   // 실제 인코딩된 시각 갱신 (append 실패 시엔 갱신 안 됨 → 정지로 잡힘)
            }
            // 세그먼트 선제 로테이션 — 방금 프레임까지 담아 확정하고, 다음 프레임이
            // 새 세그먼트를 연다. 프레임을 버리는 구간이 없고, finishWriting은
            // 다음 세그먼트가 녹화를 잇는 동안 백그라운드에서 마저 끝난다.
            if now - segmentStartedAt >= segmentRotationInterval {
                finalizeCurrentSegmentLocked()
            }
        } else if writer?.status == .failed {
            // 인코더가 죽었다(예상 밖 백그라운드·메모리 압박 등). 이 writer는 되살릴 수
            // 없고 파일도 재생 불가다 — 그 세그먼트 몫만 버리고 다음 프레임에서 새
            // 세그먼트를 연다. 사용자는 아무것도 누를 필요 없이 촬영이 조용히 이어진다.
            frameCountInternal -= segmentFrameCount
            let count = frameCountInternal
            if let url = currentSegmentURL { try? FileManager.default.removeItem(at: url) }
            self.writer = nil; self.writerInput = nil; self.adaptor = nil
            currentSegmentURL = nil
            segmentFrameCount = 0
            DispatchQueue.main.async { self.frameCount = count }
        }
    }

    private static func image(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: 사람 부재 감지 (processingQueue에서 5초마다 호출)

    /// Vision의 사람 감지로 프레임 안에 '사람의 몸'이 있는지 확인하고
    /// 연속 부재 시간을 absentSeconds로 발행한다. 완전 온디바이스라 네트워크·추가 모델 없음.
    /// 기준은 사람의 몸 — 1차 상반신 사각형, 2차 몸 포즈(뒷모습·고개 숙임 대응).
    /// 움직임은 재석 근거로 쓰지 않는다: 흔들리는 물건이 빈자리를 재석으로 못 만들고,
    /// 미동 없이 몰입한 사람은 몸이 보이는 한 재석이다.
    private func detectPresence(in buffer: CVPixelBuffer, at now: TimeInterval) {
        let rectRequest = VNDetectHumanRectanglesRequest()
        rectRequest.upperBodyOnly = true   // 책상 앞 상반신만 보여도 인식
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        try? handler.perform([rectRequest, poseRequest])
        let rectFound = !(rectRequest.results?.isEmpty ?? true)
        // 포즈: 신뢰도 있는 관절이 4개 이상이면 몸으로 인정
        let poseFound = (poseRequest.results ?? []).contains { observation in
            let joints = (try? observation.recognizedPoints(.all)) ?? [:]
            return joints.values.filter { $0.confidence > 0.3 }.count >= 4
        }
        let personFound = rectFound || poseFound

        if personFound {
            absenceStartedAt = nil
            DispatchQueue.main.async {
                if self.absentSeconds != 0 { self.absentSeconds = 0 }
            }
        } else {
            if absenceStartedAt == nil { absenceStartedAt = now }
            let seconds = Int(now - (absenceStartedAt ?? now))
            DispatchQueue.main.async { self.absentSeconds = seconds }
        }
    }

}

// MARK: - SwiftUI 프리뷰 레이어

import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// 세션 방향 (레이아웃 참고용 — 실제 프리뷰 회전은 RotationCoordinator가 담당)
    var orientation: SessionOrientation = .portrait
    /// true = 화면 꽉 채움(살짝 잘릴 수 있음), false = 촬영되는 그대로(잘림 없음, 구도용)
    var fill: Bool = true

    /// 앱 전체 단일 프리뷰 뷰.
    /// previewLayer.session 연결은 '실행 중인 세션과의 동기화' 때문에 메인 스레드를
    /// 수 초 블록할 수 있다 — 화면(거치 가이드→세션)마다 새로 만들지 않고 이 뷰 하나를
    /// 옮겨 붙인다(re-parent는 비용 0). 세션 연결은 최초 1회만 일어난다.
    @MainActor static let sharedView = PreviewUIView()

    /// 프리뷰 레이어. RotationCoordinator가 카메라·기기 방향에 맞는 각도를 실시간 반영.
    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        private var trackedDevice: AVCaptureDevice?

        /// 현재 입력 카메라가 바뀌면(전/후면 전환) 코디네이터를 다시 만든다.
        func syncCoordinator(session: AVCaptureSession) {
            let device = (session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) })?.device
            guard let device, device !== trackedDevice else { return }
            trackedDevice = device
            observation = nil
            let coord = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            coordinator = coord
            applyRotation()
            observation = coord.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
                [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            }
        }

        private func applyRotation() {
            guard let coordinator, let connection = previewLayer.connection else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        adoptShared(into: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        adoptShared(into: container)
    }

    /// 공유 프리뷰 뷰를 이 컨테이너로 입양하고 표시 설정을 맞춘다.
    private func adoptShared(into container: UIView) {
        let shared = Self.sharedView
        if shared.previewLayer.session !== session {
            shared.previewLayer.session = session   // 최초 1회만 (그 뒤엔 항상 동일 세션)
            shared.previewLayer.connection?.automaticallyAdjustsVideoMirroring = true
        }
        shared.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        shared.syncCoordinator(session: session)

        if shared.superview !== container {
            shared.removeFromSuperview()   // 이전 화면에서 분리 (동시 표시 없음)
            shared.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(shared)
            NSLayoutConstraint.activate([
                shared.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                shared.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                shared.topAnchor.constraint(equalTo: container.topAnchor),
                shared.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }
}
