//
//  AuthView.swift
//  TimeLock
//
//  출석부 — 로그인/회원가입.
//  상점·벌점·성공캘린더는 계정에 귀속되므로, 온보딩 직후 이 화면이 문지기가 된다.
//  이메일 · Google · Apple · 게스트(기기 전용) 네 가지 입장 방법.
//  디자인: 다크룸 무드 유지, 시그니처 REC 링이 '출석 도장'이 된다.
//

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case signIn, signUp

        var title: String {
            self == .signIn ? String(localized: "Log In") : String(localized: "Sign Up")
        }
    }

    @State private var mode: Mode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?   // 재설정 메일 발송 등 성공 안내
    @FocusState private var focusedField: Field?
    private enum Field { case name, email, password, passwordConfirm }

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            RadialGradient(colors: [TL.rec.opacity(0.10), .clear],
                           center: .top, startRadius: 20, endRadius: 380)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header

                    if let pendingEmail = account.pendingVerificationEmail {
                        verificationPanel(email: pendingEmail)
                            .padding(.top, 28)
                    } else {
                        modePicker
                            .padding(.top, 28)
                        fields
                            .padding(.top, 16)
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TL.rec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    if let infoMessage, !infoMessage.isEmpty {
                        Label(infoMessage, systemImage: "envelope.badge.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TL.jade)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }

                    if account.pendingVerificationEmail == nil {
                        primaryButton
                            .padding(.top, 16)
                        if mode == .signIn {
                            resetPasswordButton
                                .padding(.top, 14)
                        }
                        divider
                            .padding(.vertical, 22)
                        guestButton
                        socialButtons
                            .padding(.top, 20)
                    }

                    Text("All video recordings are stored only on this device.\nBy continuing, you agree to the Terms of Use and Privacy Policy.")
                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.top, 18)
                    LegalLinksRow()
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .animation(TLMotion.smooth, value: account.pendingVerificationEmail)
        }
        .preferredColorScheme(.dark)
        .onChange(of: account.currentUser) { _, user in
            if user != nil { dismiss() }
        }
    }

    // MARK: 헤더

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Record your focus with timelapse\nfor even stronger accountability")
                .font(.tlTitle(26))
                .foregroundStyle(TL.paper)
                .lineSpacing(5)
                .padding(.top, 56)
            Text("Tap a button below\nto log in or sign up.")
                .font(.system(size: 14))
                .foregroundStyle(TL.muted)
                .lineSpacing(4)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 로그인 / 회원가입 전환

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { candidate in
                Button {
                    mode = candidate
                    errorMessage = nil
                    infoMessage = nil
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(mode == candidate ? TL.ink : TL.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(mode == candidate ? TL.paper : .clear)
                        )
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(TL.surface))
        .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))
    }

    // MARK: 입력 필드

    private var fields: some View {
        VStack(spacing: 10) {
            if mode == .signUp {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .email }
                    .authFieldStyle()
            }

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .authFieldStyle()

            SecureField(mode == .signUp ? String(localized: "Password (8+ characters)") : String(localized: "Password"), text: $password)
                .textContentType(mode == .signUp ? .newPassword : .password)
                .focused($focusedField, equals: .password)
                .submitLabel(mode == .signUp ? .next : .go)
                .onSubmit { mode == .signUp ? (focusedField = .passwordConfirm) : submit() }
                .authFieldStyle()

            if mode == .signUp {
                SecureField("Confirm Password", text: $passwordConfirm)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .passwordConfirm)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .authFieldStyle()
                if !passwordConfirm.isEmpty && password != passwordConfirm {
                    Label("Passwords don't match", systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TL.rec)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("A verification email will be sent to the address you enter.")
                    .font(.system(size: 11)).foregroundStyle(TL.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var formReady: Bool {
        if email.isEmpty || password.isEmpty { return false }
        if mode == .signUp {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && password == passwordConfirm
        }
        return true
    }

    private var primaryButton: some View {
        Button {
            submit()
        } label: {
            Text(working ? String(localized: "Checking…") : mode.title)
        }
        .buttonStyle(TLPrimaryButtonStyle())
        .disabled(working || !formReady)
        .opacity(formReady ? 1 : 0.5)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(TL.hairline).frame(height: 1)
            Text("or")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TL.faint)
            Rectangle().fill(TL.hairline).frame(height: 1)
        }
    }

    // MARK: 소셜 로그인

    private var socialButtons: some View {
        VStack(spacing: 10) {
            // 네이티브 버튼은 탭 동작만 담당하고(거의 투명), 텍스트·로고는 구글 버튼과
            // 같은 스타일로 직접 그린다 — 두 버튼의 폰트 크기가 서로 달라 보이는 문제 수정.
            ZStack {
                SignInWithAppleButton(.continue) { request in
                    account.prepareAppleRequest(request)
                } onCompletion: { result in
                    run { try await account.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .opacity(0.02)

                HStack(spacing: 10) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(TL.ink)
                    Text("Continue with Apple")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(TL.ink)
                }
                .allowsHitTesting(false)
            }
            .frame(height: 50)
            .background(Color.white, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))

            Button {
                run { try await account.signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    Image("GoogleLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("Continue with Google")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(TL.ink)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.white, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
            }
            .disabled(working)
        }
    }

    /// 비밀번호 찾기 — 입력한 이메일로 Firebase 재설정 메일(한국어 템플릿) 발송
    private var resetPasswordButton: some View {
        Button("Forgot Password?") {
            run {
                try await account.sendPasswordReset(email: email)
                await MainActor.run {
                    infoMessage = String(localized: "We sent a reset email. Open the link in your inbox (check spam too), set a new password, then log in again.")
                }
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(TL.paper)
        .disabled(working)
    }

    private var guestButton: some View {
        Button {
            account.continueAsGuest()
        } label: {
            Text("Continue as Guest")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(TL.paper)
        }
        .disabled(working)
    }

    // MARK: 이메일 인증 대기 패널 — 인증을 마쳐야 입장 가능

    @ViewBuilder
    private func verificationPanel(email: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 40))
                .foregroundStyle(TL.amber)

            VStack(spacing: 6) {
                Text("Email Verification Needed")
                    .font(.tlTitle(20)).foregroundStyle(TL.paper)
                Text(String(format: String(localized: "We sent a verification email to %@.\nTap the link in your inbox, then tap the button below."), email))
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                run { try await account.confirmEmailVerified() }
            } label: {
                Text(working ? String(localized: "Checking…") : String(localized: "I've Verified"))
            }
            .buttonStyle(TLPrimaryButtonStyle())
            .disabled(working)

            HStack(spacing: 18) {
                Button("Resend Verification Email") {
                    run {
                        try await account.resendVerificationEmail()
                        await MainActor.run { errorMessage = String(localized: "We resent the verification email. Please check your inbox (including spam).") }
                    }
                }
                Button("Use a Different Account") {
                    errorMessage = nil
                    account.cancelPendingVerification()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TL.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
    }

    // MARK: 동작

    private func submit() {
        guard formReady else { return }
        run {
            if mode == .signIn {
                try await account.signIn(email: email, password: password)
            } else {
                try await account.signUp(email: email, password: password, displayName: name)
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        errorMessage = nil
        infoMessage = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await operation()
            } catch let error as AuthError {
                if case .cancelled = error { return }
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 필드 스타일

private extension View {
    func authFieldStyle() -> some View {
        self
            .font(.tlBody)
            .foregroundStyle(TL.paper)
            .padding(14)
            .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                    .strokeBorder(TL.hairline, lineWidth: 1)
            )
    }
}
