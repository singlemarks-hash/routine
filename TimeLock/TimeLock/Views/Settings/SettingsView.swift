//
//  SettingsView.swift
//  TimeLock
//
//  계정(로그인/로그아웃, 내 상점·벌점), 강도 변경(상향 즉시/하향 다음날 0시, 미친 매운맛 해금),
//  프라이버시 정책과 기록 삭제, 점수 원장 내역, 구독 관리.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.modelContext) private var context
    @Query(sort: \ScoreEvent.timestamp, order: .reverse) private var everyEvent: [ScoreEvent]
    @Query private var everySession: [FocusSession]

    @State private var showPaywall = false
    @State private var showAuth = false
    @State private var showDeleteAllConfirm = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var deletingAccount = false
    @State private var deleteAccountError: String?

    /// 현재 계정의 기록만
    private var events: [ScoreEvent] {
        everyEvent.filter { $0.ownerUserID == account.currentUserID }
    }
    private var sessions: [FocusSession] {
        everySession.filter { $0.ownerUserID == account.currentUserID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    accountSection
                    intensitySection
                    subscriptionSection
                    privacySection
                    ledgerSection
                    aboutSection
                }
                .padding(20)
                .padding(.bottom, 32)
            }
            .background(TL.ink)
            .navigationTitle("설정")
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showAuth) { AuthView() }
        }
    }

    // MARK: 계정

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "계정")
            if let user = account.currentUser, user.provider != .guest {
                TLCard(raised: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(TL.rec.opacity(0.2))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text(String((user.displayName ?? user.email ?? "?").prefix(1)).uppercased())
                                        .font(.tlTitle(18))
                                        .foregroundStyle(TL.rec)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.displayName ?? user.email ?? "회원")
                                    .font(.tlTitle(16)).foregroundStyle(TL.paper)
                                if let email = user.email {
                                    Text(email).font(.system(size: 12)).foregroundStyle(TL.muted)
                                }
                            }
                            Spacer()
                            TagChip(name: user.provider.title)
                        }

                        Divider().overlay(TL.hairline)

                        HStack(spacing: 0) {
                            scoreStat(value: "+\(myReward)", label: "내 상점", tint: TL.jade)
                            scoreStat(value: "\(myPenalty)", label: "내 벌점", tint: TL.rec)
                            scoreStat(value: "\(myReward + myPenalty)", label: "총점",
                                      tint: myReward + myPenalty >= 0 ? TL.paper : TL.rec)
                        }

                        Divider().overlay(TL.hairline)

                        HStack {
                            Button("로그아웃") { showSignOutConfirm = true }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TL.muted)
                            Spacer()
                            Button {
                                showDeleteAccountConfirm = true
                            } label: {
                                if deletingAccount {
                                    ProgressView().tint(TL.rec)
                                } else {
                                    Text("계정 삭제")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(TL.rec)
                                }
                            }
                            .disabled(deletingAccount)
                        }
                    }
                }
            } else {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("게스트 모드")
                            .font(.tlTitle(16)).foregroundStyle(TL.paper)
                        Text("상점·벌점이 이 기기에만 저장됩니다. 로그인하면 지금까지의 기록이 계정으로 옮겨지고, 기기를 바꿔도 유지됩니다.")
                            .font(.system(size: 13)).foregroundStyle(TL.muted)
                        Button("계정 만들기 · 로그인") { showAuth = true }
                            .buttonStyle(TLPrimaryButtonStyle())
                    }
                }
            }
        }
        .confirmationDialog("로그아웃할까요?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) { account.signOut() }
        } message: {
            Text("기록은 계정에 남아 있고, 다시 로그인하면 그대로 보입니다.")
        }
        .confirmationDialog("계정을 삭제할까요?", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
            Button("계정 영구 삭제", role: .destructive) { deleteAccount() }
        } message: {
            Text("이 기기의 예약·세션·촬영본과 개인정보가 즉시 완전 삭제되고 되돌릴 수 없습니다. 운영 통계는 개인 식별정보를 제거한 채 3개월간 보관 후 파기됩니다.")
        }
        .alert("계정 삭제", isPresented: .constant(deleteAccountError != nil)) {
            Button("확인") { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
    }

    private func deleteAccount() {
        deletingAccount = true
        deleteAccountError = nil
        Task {
            defer { deletingAccount = false }
            do {
                try await account.deleteAccount()
                // 성공 시 onUserChanged가 인증 화면으로 라우팅
            } catch {
                deleteAccountError = error.localizedDescription
            }
        }
    }

    private var myReward: Int { events.filter { $0.points > 0 }.reduce(0) { $0 + $1.points } }
    private var myPenalty: Int { events.filter { $0.points < 0 }.reduce(0) { $0 + $1.points } }

    private func scoreStat(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.tlTimer(18)).foregroundStyle(tint)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 강도

    private var intensitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "강도 · 앱 전체에 하나만 적용")
            VStack(spacing: 10) {
                intensityRow(.spicy)
                intensityRow(.insane)
            }
            if app.downgradePending, let date = app.downgradeDate {
                Label("매운맛으로 하향 예약됨 — \(TLFormat.dayTitle(date)) 0시 적용",
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TL.amber)
            }
            Text("올리는 건 즉시 적용되고, 내리는 건 다음날 0시부터 적용됩니다. 미친 매운맛은 매운맛 완주 3회 후 해금됩니다. (현재 \(min(app.spicyCompletions, 3))/3)")
                .font(.system(size: 12))
                .foregroundStyle(TL.faint)
        }
    }

    private func intensityRow(_ target: Intensity) -> some View {
        let selected = app.intensity == target
        let locked = target == .insane && !app.insaneUnlocked
        return Button {
            guard !selected, !locked else { return }
            app.requestIntensityChange(to: target)
        } label: {
            IntensityCard(intensity: target, selected: selected, locked: locked)
        }
        .buttonStyle(.plain)
    }

    // MARK: 구독

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "구독")
            TLCard(raised: subscription.isPro) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(subscription.isPro ? "앵그리모티 프로 사용 중" : "앵그리모티 프로")
                                .font(.tlTitle(17)).foregroundStyle(TL.paper)
                            Text(subscription.isPro
                                 ? "저장하는 타임랩스의 워터마크를 제거할 수 있습니다."
                                 : "타임랩스 저장 시 워터마크를 제거합니다.")
                                .font(.system(size: 13)).foregroundStyle(TL.muted)
                        }
                        Spacer()
                        if subscription.isPro {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(TL.jade).font(.title3)
                        }
                    }
                    if !subscription.isPro {
                        Button("구독하기") { showPaywall = true }
                            .buttonStyle(TLPrimaryButtonStyle(tint: TL.jade))
                    }
                    Button("구매 복원") {
                        Task { await subscription.restore() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TL.muted)
                }
            }
        }
    }

    // MARK: 프라이버시

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "프라이버시")
            TLCard {
                VStack(alignment: .leading, spacing: 12) {
                    privacyRow(icon: "arrow.down.circle.fill", text: "촬영본은 세션 종료 화면에서 사진 앱으로 저장하지 않으면 즉시 삭제됩니다. 서버로 전송되지 않습니다.")
                    privacyRow(icon: "eye.fill", text: "촬영 중에는 화면에 REC 표시와 프리뷰가 항상 보입니다.")
                    privacyRow(icon: "key.fill", text: "촬영 중 파일은 iOS 파일 보호(완전 암호화)로 저장됩니다.")
                    privacyRow(icon: "trash.fill", text: "기록 썸네일은 아래에서 언제든 완전히 삭제할 수 있습니다.")
                    Divider().overlay(TL.hairline)
                    Button("기록 썸네일 전체 삭제") { showDeleteAllConfirm = true }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TL.rec)
                }
            }
        }
        .confirmationDialog("모든 기록 썸네일을 삭제할까요?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("전체 삭제 (기록·점수는 유지)", role: .destructive) { deleteAllVideos() }
        } message: {
            Text("삭제한 썸네일은 복구할 수 없습니다. 세션 기록과 점수 원장은 유지됩니다.")
        }
    }

    private func privacyRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(TL.jade).frame(width: 20)
            Text(text).font(.system(size: 13)).foregroundStyle(TL.muted)
        }
    }

    private func deleteAllVideos() {
        for session in sessions {
            SessionStorage.deleteFiles(of: session)
            session.videoFileName = nil
            session.thumbnailFileName = nil
        }
        try? context.save()
    }

    // MARK: 점수 원장

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "점수 원장 · 최근 20건")
            if events.isEmpty {
                TLCard {
                    Text("아직 기록이 없습니다. 첫 세션을 완주하면 상점이 적립됩니다.")
                        .font(.system(size: 13)).foregroundStyle(TL.muted)
                }
            } else {
                TLCard {
                    VStack(spacing: 0) {
                        ForEach(Array(events.prefix(20).enumerated()), id: \.element.id) { index, event in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.type.title)
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(TL.paper)
                                    Text("\(event.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(event.intensity.title)\(event.note.map { " · \($0)" } ?? "")")
                                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(event.points > 0 ? "+\(event.points)" : "\(event.points)")
                                    .font(.tlTimer(15))
                                    .foregroundStyle(event.points > 0 ? TL.jade : TL.rec)
                            }
                            .padding(.vertical, 9)
                            if index < min(events.count, 20) - 1 {
                                Divider().overlay(TL.hairline.opacity(0.6))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 정보

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TLEyebrow(text: "앵그리모티")
            Text("알람을 끄는 유일한 방법, 촬영 시작. · v1.0.0")
                .font(.system(size: 12)).foregroundStyle(TL.faint)
        }
    }
}

// MARK: - 페이월

struct PaywallView: View {
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                RECRingDial(progress: 1, live: false, tint: TL.jade) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(TL.jade)
                }
                .frame(width: 150, height: 150)

                Text("앵그리모티 프로")
                    .font(.tlTitle(26)).foregroundStyle(TL.paper)
                    .padding(.top, 24)
                Text("내 완주 기록을 워터마크 없이 공유하세요.")
                    .font(.tlBody).foregroundStyle(TL.muted)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 12) {
                    benefit("타임랩스 저장 시 워터마크 제거")
                    benefit("완주 영상 원본 화질 저장")
                    benefit("앞으로 추가되는 프로 기능 전부")
                }
                .padding(.top, 28)

                Spacer()

                if let product = subscription.product {
                    Button {
                        purchasing = true
                        Task {
                            defer { purchasing = false }
                            if (try? await subscription.purchase()) == true { dismiss() }
                        }
                    } label: {
                        Text(purchasing ? "처리 중…" : "\(product.displayPrice) / 월 구독하기")
                    }
                    .buttonStyle(TLPrimaryButtonStyle(tint: TL.jade))
                    .disabled(purchasing)
                } else {
                    Text("구독 상품을 불러오는 중입니다…")
                        .font(.system(size: 13)).foregroundStyle(TL.faint)
                }

                Button("구매 복원") {
                    Task {
                        await subscription.restore()
                        if subscription.isPro { dismiss() }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TL.muted)
                .padding(.top, 12)

                Text("월 단위 자동 갱신 · 언제든 App Store에서 해지")
                    .font(.system(size: 11)).foregroundStyle(TL.faint)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
            .background(TL.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }.foregroundStyle(TL.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func benefit(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TL.jade)
            Text(text).font(.tlBody).foregroundStyle(TL.paper)
        }
    }
}
