//
//  CameraRecorder.swift
//  TimeLock
//
//  전면 카메라에서 1fps로 프레임을 뽑아 온디바이스 HEVC 타임랩스로 인코딩한다.
//  촬영 프레임 1장 = 재생 1/30초 → 1시간 세션이 2분 영상이 된다.
//  파일은 Documents/Sessions/에 완전 보호(FileProtection.complete)로 저장한다.
//

import Foundation
import AVFoundation
import UIKit

final class CameraRecorder: NSObject, ObservableObject {
    static let shared = CameraRecorder()

    @Published var isAuthorized = false
    @Published private(set) var frameCount: Int = 0

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
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
        captureSession.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90   // 세로 고정
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        captureSession.commitConfiguration()
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

    func startRecording(sessionID: UUID) throws {
        let fileName = "\(sessionID.uuidString).mov"
        let url = SessionStorage.directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // 입력 해상도는 첫 프레임에서 확정하므로, 720p 세로 기준으로 초기화
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 720,
            AVVideoHeightKey: 1280,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: playbackFPS
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 720,
                kCVPixelBufferHeightKey as String: 1280
            ])
        guard writer.canAdd(input) else { throw RecorderError.writerSetupFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        processingQueue.sync {
            self.writer = writer
            self.writerInput = input
            self.adaptor = adaptor
            self.outputURL = url
            self.thumbnailImage = nil
            self.lastCaptureAt = 0
            self.frameCountInternal = 0   // 미초기화 시 두 번째 세션이 즉시 완주 처리되는 버그 방지
            self.isPaused = false
            self.isRecording = true
        }
        DispatchQueue.main.async { self.frameCount = 0 }

        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        startPreview()
    }

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
              let input = writerInput, let adaptor = adaptor,
              input.isReadyForMoreMediaData,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CACurrentMediaTime()
        guard now - lastCaptureAt >= captureInterval else { return }
        lastCaptureAt = now

        let time = CMTime(value: CMTimeValue(frameCountInternal), timescale: playbackFPS)
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            frameCountInternal += 1
            let count = frameCountInternal
            if thumbnailImage == nil {
                thumbnailImage = Self.image(from: pixelBuffer)
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

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) { }
}
