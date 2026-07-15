//
//  CameraRecorder.swift
//  TimeLock
//
//  전면 카메라에서 1fps로 프레임을 뽑아 온디바이스 HEVC 타임랩스로 인코딩한다.
//  촬영 프레임 1장 = 재생 1/30초 → 1시간 세션이 2분 영상이 된다.
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

final class CameraRecorder: NSObject, ObservableObject {
    static let shared = CameraRecorder()

    @Published var isAuthorized = false
    @Published private(set) var frameCount: Int = 0
    /// 현재 카메라 (기본 전면 — selfie 카드의 전환 버튼으로 변경)
    @Published private(set) var position: AVCaptureDevice.Position = .front

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    /// 촬영 시작 시 확정되는 세션 방향 (도중 변경 없음)
    private var sessionOrientation: SessionOrientation = .portrait
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

    /// 타임랩스 밀도: 1초에 1프레임
    private let captureInterval: TimeInterval = 1.0
    /// 재생 프레임레이트
    private let playbackFPS: Int32 = 30

    // MARK: 권한 & 세션 구성

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

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.commitConfiguration()
        applyConnectionSettings()
    }

    private func makeInput(position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            return nil
        }
        return try? AVCaptureDeviceInput(device: device)
    }

    /// 데이터 출력 연결 설정. 버퍼는 회전하지 않고 네이티브 가로 그대로 받는다.
    /// (회전은 저장 시 writer transform으로 처리 — 늘어남 방지)
    /// 저장 영상은 미러링하지 않는다(실제 방향 보존). 프리뷰는 레이어가 알아서 미러링.
    private func applyConnectionSettings() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
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
        } else if let current = currentInput, captureSession.canAddInput(current) {
            captureSession.addInput(current)   // 실패 시 원복
        }
        captureSession.commitConfiguration()
        applyConnectionSettings()
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
    func startRecording(sessionID: UUID, orientation: SessionOrientation) throws {
        configureSessionIfNeeded()
        sessionOrientation = orientation
        applyConnectionSettings()

        let fileName = "\(sessionID.uuidString).mov"
        let url = SessionStorage.directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        processingQueue.sync {
            self.writer = nil            // 첫 프레임에서 생성
            self.writerInput = nil
            self.adaptor = nil
            self.outputURL = url
            self.thumbnailImage = nil
            self.lastCaptureAt = 0
            self.frameCountInternal = 0
            self.isPaused = false
            self.isRecording = true
        }
        DispatchQueue.main.async { self.frameCount = 0 }
        startPreview()
    }

    /// 첫 프레임의 확정된 크기로 writer를 생성 (processingQueue에서 호출)
    private func setupWriter(width: Int, height: Int) {
        guard let url = outputURL else { return }
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
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch { }
    }

    /// 네이티브 버퍼를 원하는 방향으로 세운다. 이미 맞으면 원본 그대로.
    private func orientedBuffer(_ src: CVPixelBuffer, want portrait: Bool) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let isPortrait = h > w
        guard isPortrait != portrait else { return src }   // 이미 원하는 방향
        // 90° 회전 (CIImage .right = 시계방향). 필요 시 .left로 바꾸면 반대 방향.
        let ci = CIImage(cvPixelBuffer: src).oriented(.right)
        let outW = Int(ci.extent.width), outH = Int(ci.extent.height)
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        guard let dst = out else { return src }
        let normalized = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX,
                                                              y: -ci.extent.minY))
        ciRenderContext.render(normalized, to: dst)
        return dst
    }

    private let ciRenderContext = CIContext()

    func pause()  { processingQueue.async { self.isPaused = true } }
    func resume() { processingQueue.async { self.isPaused = false } }

    struct RecordingResult {
        let videoFileName: String
        let thumbnailFileName: String?
        let frames: Int
    }

    enum RecorderError: Error { case writerSetupFailed, notRecording }

    /// 녹화 종료. 인코딩을 마무리하고 파일명/썸네일을 반환한다.
    func stopRecording() async -> RecordingResult? {
        var localWriter: AVAssetWriter?
        var localInput: AVAssetWriterInput?
        var localURL: URL?
        var localThumb: UIImage?
        var frames = 0

        processingQueue.sync {
            guard isRecording else { return }
            isRecording = false
            localWriter = writer
            localInput = writerInput
            localURL = outputURL
            localThumb = thumbnailImage
            frames = frameCountInternal
            writer = nil; writerInput = nil; adaptor = nil
        }
        guard let w = localWriter, let input = localInput, let url = localURL else { return nil }

        input.markAsFinished()
        await w.finishWriting()
        stopPreview()

        var thumbName: String?
        if let thumb = localThumb, let data = thumb.jpegData(compressionQuality: 0.8) {
            let name = url.deletingPathExtension().lastPathComponent + "-thumb.jpg"
            let thumbURL = SessionStorage.directory.appendingPathComponent(name)
            try? data.write(to: thumbURL, options: [.completeFileProtection])
            thumbName = name
        }
        return RecordingResult(videoFileName: url.lastPathComponent,
                               thumbnailFileName: thumbName,
                               frames: frames)
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
        guard now - lastCaptureAt >= captureInterval else { return }
        lastCaptureAt = now

        // 원하는 방향으로 세운 버퍼 (필요할 때만 회전)
        let buffer = orientedBuffer(source, want: sessionOrientation.wantsPortraitFrame)

        // 첫 프레임에서 확정된 크기로 writer 생성
        if writer == nil {
            setupWriter(width: CVPixelBufferGetWidth(buffer),
                        height: CVPixelBufferGetHeight(buffer))
        }
        guard let input = writerInput, let adaptor = adaptor,
              input.isReadyForMoreMediaData else { return }

        let time = CMTime(value: CMTimeValue(frameCountInternal), timescale: playbackFPS)
        if adaptor.append(buffer, withPresentationTime: time) {
            frameCountInternal += 1
            let count = frameCountInternal
            if thumbnailImage == nil {
                thumbnailImage = Self.image(from: buffer)   // 이미 올바로 세워진 버퍼
            }
            DispatchQueue.main.async { self.frameCount = count }
        }
    }

    private static func image(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - SwiftUI 프리뷰 레이어

import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// 세션 방향과 동일하게 고정 (구도 단계에서 토글하면 갱신됨)
    var orientation: SessionOrientation = .portrait
    /// true = 화면 꽉 채움(살짝 잘릴 수 있음), false = 촬영되는 그대로(잘림 없음, 구도용)
    var fill: Bool = true

    /// 프리뷰 회전각 — 녹화 파이프라인과 동일하게 맞춘다.
    /// 네이티브 버퍼가 세로·정립이므로 세로 모드는 회전 0, 가로 모드는 90° 돌려 가로로.
    private var rotationAngle: CGFloat { orientation == .portrait ? 0 : 90 }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var angle: CGFloat = 90 {
            didSet { applyRotation() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyRotation()
        }

        private func applyRotation() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        // 프리뷰는 전면 카메라를 자연스러운 셀피처럼 좌우 반전 (저장본은 반전 안 함)
        view.previewLayer.connection?.automaticallyAdjustsVideoMirroring = true
        view.angle = rotationAngle
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        uiView.angle = rotationAngle
    }
}
