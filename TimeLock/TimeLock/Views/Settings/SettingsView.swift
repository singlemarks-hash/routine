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
import StoreKit   // CheerDeveloperView의 @Environment(\.requestReview)에 필요

// MARK: - 마이페이지 (메뉴 허브)

struct MyPageView: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 아이콘 메뉴 그룹
                VStack(spacing: 4) {
                    iconRow(icon: "person.crop.circle.badge.checkmark", title: String(localized: "Profile & Subscription")) {
                        ProfileEditView()
                    }
                    iconRow(icon: "headphones", title: String(localized: "Support")) {
                        SupportView()
                    }
                    iconRow(icon: "heart.text.square", title: String(localized: "Support the Developer")) {
                        CheerDeveloperView()
                    }
                }

                Divider().overlay(TL.hairline)

                // 일반 메뉴 그룹
                VStack(spacing: 4) {
                    // 강도는 활동/그룹별로 각각 설정 — 전역 강도 탭 제거
                    plainRow(title: String(localized: "Privacy")) { PrivacySettingsView() }
                    plainRow(title: String(localized: "Score Ledger")) { LedgerView() }
                    plainRow(title: String(localized: "App Language")) { AppLanguageView() }
                    linkRow(title: String(localized: "Terms of Use"), url: Legal.termsOfUseURL)
                    linkRow(title: String(localized: "Privacy Policy"), url: Legal.privacyPolicyURL)
                }

                // 팀 시그니처 — 흐리고 작게
                Text("Culture Design Corperation ‘      ‘")
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(TL.faint.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }
            .padding(20)
            .padding(.bottom, 32)
        }
        .background(TL.ink)
        .navigationTitle("My Page")
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
    @State private var restoreMessage: String?

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
                                Text("Email verification pending — check your inbox")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TL.amber)
                                Spacer()
                                Button("Resend") {
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
                                    Text(user.displayName ?? user.email ?? String(localized: "Member"))
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
                                stat(value: "+\(myReward)", label: String(localized: "My Points"), tint: TL.jade)
                                stat(value: "\(myPenalty)", label: String(localized: "My Penalty"), tint: TL.rec)
                                stat(value: "\(myReward + myPenalty)", label: String(localized: "Total"),
                                     tint: myReward + myPenalty >= 0 ? TL.paper : TL.rec)
                            }

                            // 로그아웃 — 프로필 카드 안, 점수 아래 가운데 정렬
                            Button("Log Out") { showSignOutConfirm = true }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TL.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 2)
                        }
                    }

                    // 구독 카드
                    TLEyebrow(text: String(localized: "Subscription"))
                    TLCard(raised: subscription.isPro) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(subscription.isPro ? String(localized: "AngryMoti Membership Active") : String(localized: "AngryMoti Membership"))
                                        .font(.tlTitle(17)).foregroundStyle(TL.paper)
                                    Text(subscription.isPro
                                         ? String(format: String(localized: "Membership perks active — %ld+ slots, no watermark, Insane mode."), SlotPolicy.memberFloorSlots)
                                         : String(format: String(localized: "%ld+ slots · No watermark · Insane mode unlocked instantly."), SlotPolicy.memberFloorSlots))
                                        .font(.system(size: 13)).foregroundStyle(TL.muted)
                                }
                                Spacer()
                                if subscription.isPro {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(TL.jade).font(.title3)
                                }
                            }
                            if !subscription.isPro {
                                Button("Subscribe") { showPaywall = true }
                                    .buttonStyle(TLPrimaryButtonStyle(tint: TL.jade))
                            }
                            Button("Restore Purchases") {
                                Task {
                                    if await subscription.restore() == false {
                                        restoreMessage = Legal.restoreNotFoundMessage
                                    }
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TL.muted)
                        }
                    }
                    Text(Legal.subscriptionDisclosure)
                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                    LegalLinksRow()

                    // 계정 삭제 — 최하단 큰 버튼 (진한 회색, 가운데 정렬)
                    Button {
                        showDeleteAccountConfirm = true
                    } label: {
                        Group {
                            if deletingAccount {
                                ProgressView().tint(TL.rec)
                            } else {
                                Text("Delete Account")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(TL.rec)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                            .fill(TL.raised))
                    }
                    .disabled(deletingAccount)
                    .padding(.top, 18)
                } else {
                    guestCard { showAuth = true }
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("Profile & Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refreshEmailVerification() }
        .sheet(isPresented: $showAuth) { AuthView() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .confirmationDialog("Log out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { account.signOut() }
        } message: {
            Text("Your records stay on your account and will be there when you log back in.")
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
            Button("Permanently Delete Account", role: .destructive) { deleteAccount() }
        } message: {
            Text("Activities, sessions, and recordings on this device, plus your account and server data, will be permanently deleted immediately. This can't be undone.")
        }
        .alert("Delete Account", isPresented: .constant(deleteAccountError != nil)) {
            Button("OK") { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) { restoreMessage = nil }
        } message: {
            Text(restoreMessage ?? "")
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
            Text("Guest Mode")
                .font(.tlTitle(16)).foregroundStyle(TL.paper)
            Text("Guest records are stored only on this device, separate from any account. Create an account and future records will be saved there, surviving a device change.")
                .font(.system(size: 13)).foregroundStyle(TL.muted)
            Button("Create Account · Log In", action: onLogin)
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
                        Text("Contact Us")
                            .font(.tlTitle(16)).foregroundStyle(TL.paper)
                        Text("Send us any issues or questions you have while using the app.")
                            .font(.system(size: 13)).foregroundStyle(TL.muted)
                        Link("Email singlemarks@gmail.com",
                             destination: URL(string: "mailto:singlemarks@gmail.com")!)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.jade)
                    }
                }
                TLCard {
                    Text("An FAQ is coming soon.")
                        .font(.system(size: 13)).foregroundStyle(TL.faint)
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 개발자 응원하기 (뼈대)

struct CheerDeveloperView: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AngryMoti is being built by Team Singlemark")
                            .font(.tlTitle(16)).foregroundStyle(TL.paper)
                        Text("We dream of a world where everyone can finally say \u{2018}I did it\u{2019} to that one bucket-list goal they carry in their heart. Until that meaningful goal becomes real, AngryMoti will keep building what it takes to get you there.")
                            .font(.system(size: 13)).foregroundStyle(TL.muted)
                    }
                }

                // 리뷰 남기기 — 딥링크가 있으면 App Store 작성 페이지, 없으면 시스템 평점 프롬프트.
                // 아이콘을 텍스트 옆에 붙이면 아이콘 쪽으로 무게가 쏠려 가운데 정렬처럼
                // 안 보인다 — 다른 기본 버튼들과 같이 텍스트만 놓아 정렬을 맞춘다.
                Button {
                    if let url = Legal.writeReviewURL { openURL(url) }
                    else { requestReview() }
                } label: {
                    Text("Rate & Review on the App Store")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(TLPrimaryButtonStyle(tint: TL.amber))

                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Want to support us even more?")
                            .font(.tlTitle(15)).foregroundStyle(TL.paper)
                        Text("An AngryMoti Membership directly supports development while giving you perks like more slots, no watermark, and Insane mode. Get started under My Page › Profile & Subscription.")
                            .font(.system(size: 13)).foregroundStyle(TL.muted)
                        Link("Send feedback — singlemarks@gmail.com",
                             destination: URL(string: "mailto:singlemarks@gmail.com")!)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TL.jade)
                    }
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("Support the Developer")
        .navigationBarTitleDisplayMode(.inline)
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
                        privacyRow(icon: "arrow.down.circle.fill", text: "Recordings are deleted immediately unless you save them to Photos from the results screen. They're never sent to a server.")
                        privacyRow(icon: "eye.fill", text: "The REC indicator and live preview are always visible on screen while recording.")
                        privacyRow(icon: "key.fill", text: "Files are stored with iOS Data Protection (full encryption) while recording.")
                        privacyRow(icon: "trash.fill", text: "You can permanently delete record thumbnails below at any time.")
                        Divider().overlay(TL.hairline)
                        Button("Delete All Record Thumbnails") { showDeleteAllConfirm = true }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.rec)
                    }
                }
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all record thumbnails?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Delete All (records & points stay)", role: .destructive) { deleteAllVideos() }
        } message: {
            Text("Deleted thumbnails can't be recovered. Session records and the score ledger are unaffected.")
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
                TLEyebrow(text: String(localized: "Last 20 Entries"))
                if events.isEmpty {
                    TLCard {
                        Text("No entries yet. Complete your first session to start earning points.")
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
                                        Text("\(event.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(event.intensity.title)\(event.note.map { " · \(ScoreNote.label($0))" } ?? "")")
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
        .navigationTitle("Score Ledger")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 앱 언어 (뼈대)

struct AppLanguageView: View {
    /// 앱이 실제로 그려지는 언어 — 체크마크는 하드코딩이 아니라 현재 로케일을 따라간다.
    /// (예전엔 한국어에 고정 체크라 영어 기기에서 틀린 정보를 보여줬다)
    /// 인앱 전환은 Phase 4에서 설정 딥링크로 붙는다 — 여기는 현재 상태 표시만.
    private var isKorean: Bool { TLFormat.isKorean }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("한국어")   // l10n:ko-literal — 언어 자체의 이름(고유명사), 번역 대상 아님
                                .font(.tlTitle(16)).foregroundStyle(isKorean ? TL.paper : TL.faint)
                            Spacer()
                            if isKorean {
                                Image(systemName: "checkmark").foregroundStyle(TL.jade)
                            }
                        }
                        HStack {
                            Text("English")
                                .font(.tlTitle(16)).foregroundStyle(isKorean ? TL.faint : TL.paper)
                            Spacer()
                            if !isKorean {
                                Image(systemName: "checkmark").foregroundStyle(TL.jade)
                            }
                        }
                    }
                }
                Text("Follows your device language. You can change it in Settings.")
                    .font(.system(size: 12)).foregroundStyle(TL.faint)
            }
            .padding(20)
        }
        .background(TL.ink)
        .navigationTitle("App Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 페이월

struct PaywallView: View {
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 0) {
                // 멤버십 캐릭터 (moti_member)
                Image("MotiMember")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .padding(.top, 8)

                Text("AngryMoti Membership")
                    .font(.tlTitle(26)).foregroundStyle(TL.paper)
                    .padding(.top, 18)
                Text("Beyond the basics, into your own hands.")
                    .font(.tlBody).foregroundStyle(TL.muted)
                    .padding(.top, 6)

                if let trial = subscription.freeTrialDescription {
                    Text(trial)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(TL.jade)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(TL.jade.opacity(0.14)))
                        .padding(.top, 12)
                }

                VStack(alignment: .leading, spacing: 12) {
                    benefit(String(format: String(localized: "Start with at least %ld activity slots (free is 2)"), SlotPolicy.memberFloorSlots))
                    benefit(String(localized: "No timelapse watermark"))
                    benefit(String(localized: "Insane mode (members only)"))
                    benefit(String(localized: "Group Challenge — gather with an invite code and compete on the same schedule"))
                    benefit(String(localized: "Includes all future membership features too"))
                }
                .padding(.top, 24)

                Spacer(minLength: 24)

                if let product = subscription.product {
                    Button {
                        purchasing = true
                        Task {
                            defer { purchasing = false }
                            if (try? await subscription.purchase()) == true {
                                dismiss()
                            }
                        }
                    } label: {
                        Text(purchasing ? String(localized: "Processing…")
                             : subscription.freeTrialDescription != nil
                               ? String(format: String(localized: "Start Free · Then %@/mo"), product.displayPrice)
                               : String(format: String(localized: "Subscribe for %@/mo"), product.displayPrice))
                    }
                    .buttonStyle(TLPrimaryButtonStyle(tint: TL.jade))
                    .disabled(purchasing)
                } else if subscription.loadingProduct {
                    Text("Loading subscription options…")
                        .font(.system(size: 13)).foregroundStyle(TL.faint)
                } else {
                    // 조회가 끝났는데 상품이 없다 — 계속 '불러오는 중'이라고 두면
                    // 사용자는 기다리면 될 줄 알고 앱을 껐다 켜는 수밖에 없다.
                    VStack(spacing: 10) {
                        Text("Couldn't load subscription options.\nPlease check your network connection.")
                            .font(.system(size: 13)).foregroundStyle(TL.faint)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { Task { await subscription.loadProduct() } }
                            .buttonStyle(TLGhostButtonStyle())
                    }
                }

                Button("Restore Purchases") {
                    Task {
                        if await subscription.restore() { dismiss() }
                        else { restoreMessage = Legal.restoreNotFoundMessage }
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
            }   // ScrollView
            .background(TL.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundStyle(TL.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
        // 앱 실행 때 한 번 실패하면 그걸로 끝이었다 — 페이월을 열 때마다 다시 시도한다.
        // 이미 받아둔 상품이 있으면 건드리지 않는다(불필요한 스토어 조회 방지).
        .task { if subscription.product == nil { await subscription.loadProduct() } }
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) { restoreMessage = nil }
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    private func benefit(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TL.jade)
            Text(text).font(.tlBody).foregroundStyle(TL.paper)
        }
    }
}
