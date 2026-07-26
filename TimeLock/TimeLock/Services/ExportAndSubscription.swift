//
//  ExportAndSubscription.swift
//  TimeLock
//
//  1) WatermarkExporter — 내보내기 시 기본 워터마크 삽입.
//     구독(앵그리모티 멤버십) 상태에서만 워터마크 제거 토글이 동작한다.
//  2) VideoDownloader — 결과 화면의 '타임랩스 저장'. 정책상 촬영본은
//     세션 종료 직후 사진 앱으로 저장하지 않으면 자동 삭제된다.
//  3) SubscriptionManager — StoreKit 2 자동갱신 구독 관리.
//

import Foundation
import AVFoundation
import UIKit
import StoreKit
import Photos

// MARK: - 워터마크 내보내기

enum WatermarkExporter {

    enum ExportError: Error { case noVideoTrack, exportFailed }

    /// 워터마크 유무를 선택해 임시 파일로 내보낸다. (공유 시트에 전달)
    static func export(videoURL: URL, watermarked: Bool) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed
        }
        let duration = try await asset.load(.duration)
        try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        compTrack.preferredTransform = try await track.load(.preferredTransform)

        let naturalSize = try await track.load(.naturalSize)
        let renderSize = naturalSize

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        if watermarked {
            let parentLayer = CALayer()
            let videoLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            let text = CATextLayer()
            text.string = "AngryMoti"
            text.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
            text.fontSize = max(22, renderSize.width * 0.038)
            text.foregroundColor = UIColor(white: 1, alpha: 0.85).cgColor
            text.alignmentMode = .right
            // 영상 합성 레이어는 renderSize(픽셀) 기준으로 렌더되므로 화면 스케일 대신 고정값.
            // (UIScreen.main은 main-actor 격리 + deprecated라 nonisolated async에서 접근 부적합)
            text.contentsScale = 2
            let height = text.fontSize * 1.5
            text.frame = CGRect(x: 0, y: 24, width: renderSize.width - 24, height: height)
            parentLayer.addSublayer(text)

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelock-export-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.exportFailed
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        await exporter.export()
        guard exporter.status == .completed else { throw ExportError.exportFailed }
        return outURL
    }
}

// MARK: - 타임랩스 다운로드 (사진 앱 저장)

enum VideoDownloader {

    enum SaveError: LocalizedError {
        case notAuthorized
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "사진 추가 권한이 꺼져 있습니다 — iPhone 설정 › 앵그리모티에서 허용하세요."
            case .exportFailed:
                return "영상을 준비하지 못했습니다. 다시 시도하세요."
            }
        }
    }

    /// 워터마크를 적용해 내보낸 뒤 사진 라이브러리에 추가한다.
    static func saveToPhotos(videoURL: URL, watermarked: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized }

        let exportURL: URL
        do {
            exportURL = try await WatermarkExporter.export(videoURL: videoURL, watermarked: watermarked)
        } catch {
            throw SaveError.exportFailed
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportURL)
        }
    }
}

// MARK: - 구독 (앵그리모티 멤버십)

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    static let productID = "com.timelock.pro.monthly"

    @Published var isPro = false
    @Published var product: Product?

    /// 상품 조회가 진행 중인지. 실패해서 nil인 것과 아직 못 받아온 것을 화면이 구분해야
    /// '불러오는 중'이라고 거짓말하지 않는다.
    @Published var loadingProduct = false

    /// 무료 체험 자격 여부 — 이 계정/기기가 인트로 오퍼(첫 14일 무료)를 아직 쓸 수 있는지.
    /// 이미 한 번 쓴 계정이면 false가 되어 체험 문구를 숨긴다.
    @Published var isEligibleForIntro = false

    /// 반대 플랫폼(안드로이드)에서 구독한 경우의 만료 시각 — AccountStore 동기화가 채워준다.
    /// Pro 판정 = 이 기기 스토어 구독 ∨ 클라우드 기록이 아직 유효.
    var cloudProUntil: Date? { didSet { recomputeIsPro() } }
    private var storePro = false

    /// 스토어 콘솔에 무료 체험(인트로 오퍼)이 설정돼 있고, 이 계정이 아직 자격이 있으면 문구를 노출한다.
    /// (App Store Connect에서 인트로 오퍼를 등록하지 않으면 nil → 기존 문구로 자연 폴백)
    var freeTrialDescription: String? {
        guard isEligibleForIntro,
              let offer = product?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        switch offer.period.unit {
        case .day:   return "첫 \(n)일 무료"
        case .week:  return "첫 \(n * 7)일 무료"
        case .month: return "첫 \(n)개월 무료"
        case .year:  return "첫 \(n)년 무료"
        @unknown default: return "무료 체험"
        }
    }

    private func recomputeIsPro() {
        isPro = storePro || (cloudProUntil ?? .distantPast) > .now
    }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { await listenForTransactions() }
        Task {
            await loadProduct()
            await refreshEntitlement()
        }
    }

    /// 상품 조회는 실패할 수 있다 — 네트워크가 끊겼거나, 스토어 콘솔에서 상품이
    /// 아직 승인 전이거나 반려 상태일 때 빈 결과가 온다. 앱 실행 때 한 번만 부르고
    /// 말면 그 뒤로는 영영 nil이라, 페이월이 '불러오는 중'에서 멈춘 채 결제도 못 한다.
    /// 그래서 진행 중/실패를 구분해 두고, 페이월을 열 때마다 다시 시도한다.
    func loadProduct() async {
        loadingProduct = true
        defer { loadingProduct = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            // 인트로 오퍼(무료 체험) 자격 확인 — 이미 쓴 계정이면 false로 내려가 문구를 숨긴다
            if let sub = product?.subscription {
                isEligibleForIntro = await sub.isEligibleForIntroOffer
            } else {
                isEligibleForIntro = false
            }
        } catch { product = nil; isEligibleForIntro = false }
    }

    func refreshEntitlement() async {
        var pro = false
        var expires: Date?
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                pro = true
                if let e = transaction.expirationDate, e > (expires ?? .distantPast) { expires = e }
            }
        }
        storePro = pro
        recomputeIsPro()
        // 클라우드에 기록해 안드로이드 기기에서도 멤버십이 인정되게 한다.
        // 실제 만료 시각 + 3일 유예 — 유예가 없으면 자동 갱신 직후 iOS 앱을 아직 안 연
        // 동안 반대 플랫폼이 만료 시각을 지나 Pro가 잠깐 풀린다(갱신-미러 공백).
        // 3일이면 청구 재시도·시계 오차까지 덮고, 해지 후 잔존도 3일로 짧다.
        // (만료 시각이 없는 예외 케이스만 기존 35일 추정 폴백)
        if pro {
            AccountStore.shared.mirrorMembership(
                expiresAt: expires.map { $0.addingTimeInterval(3 * 86_400) }
                    ?? Date(timeIntervalSinceNow: 35 * 86_400),
                platform: "apple")
        } else if let latest = try? await Transaction.latest(for: Self.productID),
                  case .verified(let transaction) = latest,
                  transaction.revocationDate != nil {
            // 환불(revocation) 감지 — 위 미러의 만료+3일 유예 때문에 환불받은 사용자가
            // 전 플랫폼에서 잔여 기간 동안 유료 혜택을 계속 쓰는 창이 있었다. 구매 이력이
            // 있고 그것이 revoke된 '구매 플랫폼 기기'에서만 클라우드 만료를 지금으로 당긴다.
            // 자연 만료는 revocation이 아니라 여기 안 걸리므로 3일 유예 설계는 그대로고,
            // 안드로이드 구매 사용자의 iOS(storePro=false 평상시)는 애플 트랜잭션 자체가
            // 없어 지나간다. (안드로이드 쪽 환불 감지는 클라이언트로 불가능 — D6 RTDN 과제)
            AccountStore.shared.mirrorMembership(expiresAt: .now, platform: "apple")
            cloudProUntil = nil
            recomputeIsPro()
        }
    }

    func purchase() async throws -> Bool {
        guard let product else { return false }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified(let transaction) = verification {
                await transaction.finish()
                await refreshEntitlement()
                return true
            }
            return false
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    /// 복원 결과를 돌려준다. 복원은 '없는 구독을 만들어내는' 기능이 아니라
    /// '이미 있는 구독을 이 기기에 다시 인식시키는' 기능이라, 찾은 게 없으면 아무 일도
    /// 일어나지 않는 게 정상이다. 그런데 화면이 조용하면 사용자는 고장으로 읽는다.
    /// (암호까지 입력했는데 아무 변화가 없으면 특히 그렇다)
    @discardableResult
    func restore() async -> Bool {
        try? await AppStore.sync()
        await refreshEntitlement()
        return isPro
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await refreshEntitlement()
            }
        }
    }
}
