//
//  SettingsView.swift
//  TimeLock
//
//  마이페이지 — 홈 우상단 프로필 아이콘으로 진입.
//  프로필 편집 / 고객센터 / 개발자 응원하기 / 계정 관리 / 강도 설정 /
//  구독 관리 / 프라이버시 / 점수 원장 / 앱 언어 / 이용약관 / 개인정보처리방침.
//  (고객센터·개발자 응원하기·앱 언어·프로필 편집은 뼈대 — 추후 내용 연동)
//

import SwiftUI
import SwiftData

// MARK: - 마이페이지 (메뉴 허브)

struct MyPageView: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 아이콘 메뉴 그룹
                VStack(spacing: 4) {
                    iconRow(icon: "person.crop.circle.badge.checkmark", title: "프로필 및 구독 관리") {
                        ProfileEditView()
                    }
                    iconRow(icon: "headphones", title: "고객센터") {
                        SupportView()
                    }
                    iconRow(icon: "heart.text.square", title: "개발자 응원하기") {
                        CheerDeveloperView()
                    }
                }

                Divider().overlay(TL.hairline)

                // 일반 메뉴 그룹
                VStack(spacing: 4) {
                    plainRow(title: "강도 설정") { IntensitySettingsView() }
                    plainRow(title: "프라이버시") { PrivacySettingsView() }
                    plainRow(title: "점수 원장") { LedgerView() }
                    plainRow(title: "앱 언어") { AppLanguageView() }
                    linkRow(title: "이용약관", url: Legal.termsOfUseURL)
                    linkRow(title: "개인정보처리방침", url: Legal.privacyPolicyURL)
                }
            }
            .padding(20)
            .padding(.bottom, 32)
        }
        .background(TL.ink)
        .navigationTitle("마이페이지")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iconRow<D: View>(icon: String, title: String,
                                  @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(TL.paper)
                    .frame(width: 32)
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.paper)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TL.faint)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func plainRow<D: View>(title: String,
                                   @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            rowLabel(title)
        }
        .buttonStyle(.plain)
    }

    private func linkRow(title: String, url: URL) -> some View {
        Link(destination: url) {
            rowLabel(title)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TL.paper)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TL.faint)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: - 프로필 및 구독 관리 (프로필·구독·계정 관리 통합)

struct ProfileEditView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @Query(sort: \ScoreEvent.timestamp, order: .reverse) private var everyEvent: [ScoreEvent]

    @State private var showAuth = false
    @State private var showPaywall = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var deletingAccount = false
    @State private var deleteAccountError: String?

    private var events: [ScoreEvent] {
        everyEvent.filter { $0.ownerUserID == account.currentUserID }
    }
    private var myReward: Int { events.filter { $0.points > 0 }.reduce(0) { $0 + $1.points } }
    private var myPenalty: Int { events.filter { $0.points < 0 }.reduce(0) { $0 + $1.points } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let user = account.currentUser, user.provider != .guest {
                    // 이메일 인증 대기 안내
                    if !account.isEmailVerified {
                        TLCard {
                            HStack(spacing: 8) {
                                Image(systemName: "envelope.badge")
                                    .font(.system(size: 13)).foregroundStyle(TL.amber)
                                Text("이메일 인증 대기 중 — 받은 편지함을 확인하세요")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TL.amber)
                                Spacer()
                                Button("재발송") {
                                    Task { try? await account.resendVerificationEmail() }
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(TL.paper)
                            }
                        }
                    }

                    // 프로필 카드
                    TLCard(raised: true) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(TL.rec.opacity(0.2))
                                    .frame(width: 52, height: 52)
                                    .overlay(
                                        Text(String((user.displayName ?? user.email ?? "?").prefix(1)).uppercased())
                                            .font(.tlTitle(20))
                                            .foregroundStyle(TL.rec)
                                    )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.displayName ?? user.email ?? "회원")
                                        .font(.tlTitle(17)).foregroundStyle(TL.paper)
                                    if let email = user.email {
                                        Text(email).font(.system(size: 12)).foregroundStyle(TL.muted)
                                    }
                                }
                                Spacer()
                                TagChip(name: user.provider.title)
                            }

                            Divider().overlay(TL.hairline)

                            HStack(spacing: 0) {
                                stat(value: "+\(myReward)", label: "내 상점", tint: TL.jade)
                                stat(value: "\(myPenalty)", label: "내 벌점", tint: TL.rec)
                                stat(value: "\(myReward + myPenalty)", label: "총점",
                                     tint: myReward + myPenalty >= 0 ? TL.paper : TL.rec)
                            }
                        }
                    }

                    // 구독 카드
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
                    Text(Legal.subscriptionDisclosure)
                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                    LegalLinksRow()

                    // 계정 관리
                    TLEyebrow(text: "계정")
                        .padding(.top, 6)
                    TLCard {
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
                } else {
                    guestCard { showAuth = true }
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("프로필 및 구독 관리")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refreshEmailVerification() }
        .sheet(isPresented: $showAuth) { AuthView() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .confirmationDialog("로그아웃할까요?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) { account.signOut() }
        } message: {
            Text("기록은 계정에 남아 있고, 다시 로그인하면 그대로 보입니다.")
        }
        .confirmationDialog("계정을 삭제할까요?", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
            Button("계정 영구 삭제", role: .destructive) { deleteAccount() }
        } message: {
            Text("이 기기의 예약·세션·촬영본과 계정·서버 데이터가 즉시 완전 삭제되고 되돌릴 수 없습니다.")
        }
        .alert("계정 삭제", isPresented: .constant(deleteAccountError != nil)) {
            Button("확인") { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
    }

    private func stat(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.tlTimer(18)).foregroundStyle(tint)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity)
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
}

/// 게스트 상태 공용 카드
private func guestCard(onLogin: @escaping () -> Void) -> some View {
    TLCard {
        VStack(alignment: .leading, spacing: 10) {
            Text("게스트 모드")
                .font(.tlTitle(16)).foregroundStyle(TL.paper)
            Text("상점·벌점이 이 기기에만 저장됩니다. 로그인하면 지금까지의 기록이 계정으로 옮겨지고, 기기를 바꿔도 유지됩니다.")
                .font(.system(size: 13)).foregroundStyle(TL.muted)
            Button("계정 만들기 · 로그인", action: onLogin)
                .buttonStyle(TLPrimaryButtonStyle())
        }
    }
}

// MARK: - 고객센터 (뼈대)

struct SupportView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("문의하기")
                            .font(.tlTitle(16)).foregroundStyle(TL.paper)
                        Text("이용 중 불편한 점이나 궁금한 점을 보내주세요.")
                            .font(.system(size: 13)).foregroundStyle(TL.muted)
                        Link("singlemarks@gmail.com 으로 메일 보내기",
                             destination: URL(string: "mailto:singlemarks@gmail.com")!)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.jade)
                    }
                }
                TLCard {
                    Text("자주 묻는 질문(FAQ)은 준비 중입니다.")
                        .font(.system(size: 13)).foregroundStyle(TL.faint)
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("고객센터")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 개발자 응원하기 (뼈대)

struct CheerDeveloperView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("앵그리모티를 만들어가고 있어요")
                            .font(.tlTitle(16)).foregroundStyle(TL.paper)
                        Text("응원 메시지·리뷰·후원 기능은 준비 중입니다. 조금만 기다려주세요!")
                            .font(.system(size: 13)).foregroundStyle(TL.muted)
                    }
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("개발자 응원하기")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 강도 설정

struct IntensitySettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
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
                Text("올리는 건 즉시 적용되고, 내리는 건 다음날 0시부터 적용됩니다. 미친 매운맛은 매운맛 완주 3회 후 잠금 해제됩니다. (현재 \(min(app.spicyCompletions, 3))/3)")
                    .font(.system(size: 12))
                    .foregroundStyle(TL.faint)
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("강도 설정")
        .navigationBarTitleDisplayMode(.inline)
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
}

// MARK: - 프라이버시

struct PrivacySettingsView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.modelContext) private var context
    @Query private var everySession: [FocusSession]
    @State private var showDeleteAllConfirm = false

    private var sessions: [FocusSession] {
        everySession.filter { $0.ownerUserID == account.currentUserID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
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
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("프라이버시")
        .navigationBarTitleDisplayMode(.inline)
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
}

// MARK: - 점수 원장

struct LedgerView: View {
    @EnvironmentObject private var account: AccountStore
    @Query(sort: \ScoreEvent.timestamp, order: .reverse) private var everyEvent: [ScoreEvent]

    private var events: [ScoreEvent] {
        everyEvent.filter { $0.ownerUserID == account.currentUserID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TLEyebrow(text: "최근 20건")
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
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("점수 원장")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 앱 언어 (뼈대)

struct AppLanguageView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("한국어")
                                .font(.tlTitle(16)).foregroundStyle(TL.paper)
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(TL.jade)
                        }
                        HStack {
                            Text("English")
                                .font(.tlTitle(16)).foregroundStyle(TL.faint)
                            Spacer()
                            TagChip(name: "준비 중")
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("앱 언어")
        .navigationBarTitleDisplayMode(.inline)
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

                Text(Legal.subscriptionDisclosure)
                    .font(.system(size: 11)).foregroundStyle(TL.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                LegalLinksRow()
                    .padding(.top, 10)
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
