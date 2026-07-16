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
        case signIn = "로그인"
        case signUp = "회원가입"
    }

    @State private var mode: Mode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var working = false
    @State private var errorMessage: String?
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

                    if account.pendingVerificationEmail == nil {
                        primaryButton
                            .padding(.top, 16)
                        divider
                            .padding(.vertical, 22)
                        socialButtons
                        guestButton
                            .padding(.top, 26)
                    }

                    Text("계속하면 이용약관과 개인정보처리방침에 동의하는 것으로 간주됩니다.")
                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                        .multilineTextAlignment(.center)
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

    // MARK: 헤더 — 출석 도장(REC 링)

    private var header: some View {
        VStack(spacing: 0) {
            RECRingDial(progress: 1, live: false, tint: TL.rec) {
                Image(systemName: "person.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(TL.paper)
            }
            .frame(width: 92, height: 92)
            .padding(.top, 48)

            TLEyebrow(text: "앵그리모티 출석부", color: TL.rec)
                .padding(.top, 20)
            Text("기록은 계정에 남습니다")
                .font(.tlTitle(26))
                .foregroundStyle(TL.paper)
                .padding(.top, 8)
            Text("상점과 벌점은 계정별로 관리됩니다.\n기기를 바꿔도 이력이 따라옵니다.")
                .font(.system(size: 14))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 6)
        }
    }

    // MARK: 로그인 / 회원가입 전환

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { candidate in
                Button {
                    mode = candidate
                    errorMessage = nil
                } label: {
                    Text(candidate.rawValue)
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
                TextField("이름", text: $name)
                    .textContentType(.name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .email }
                    .authFieldStyle()
            }

            TextField("이메일", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .authFieldStyle()

            SecureField(mode == .signUp ? "비밀번호 (8자 이상)" : "비밀번호", text: $password)
                .textContentType(mode == .signUp ? .newPassword : .password)
                .focused($focusedField, equals: .password)
                .submitLabel(mode == .signUp ? .next : .go)
                .onSubmit { mode == .signUp ? (focusedField = .passwordConfirm) : submit() }
                .authFieldStyle()

            if mode == .signUp {
                SecureField("비밀번호 확인", text: $passwordConfirm)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .passwordConfirm)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .authFieldStyle()
                if !passwordConfirm.isEmpty && password != passwordConfirm {
                    Label("비밀번호가 서로 다릅니다", systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TL.rec)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("가입하면 입력한 주소로 인증 메일이 발송됩니다.")
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
            Text(working ? "확인 중…" : (mode == .signIn ? "로그인" : "회원가입"))
        }
        .buttonStyle(TLPrimaryButtonStyle())
        .disabled(working || !formReady)
        .opacity(formReady ? 1 : 0.5)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(TL.hairline).frame(height: 1)
            Text("또는")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TL.faint)
            Rectangle().fill(TL.hairline).frame(height: 1)
        }
    }

    // MARK: 소셜 로그인

    private var socialButtons: some View {
        VStack(spacing: 10) {
            SignInWithAppleButton(.continue) { request in
                account.prepareAppleRequest(request)
            } onCompletion: { result in
                run { try await account.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))

            Button {
                run { try await account.signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    Image("GoogleLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("Google로 계속하기")
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

    private var guestButton: some View {
        Button {
            account.continueAsGuest()
        } label: {
            VStack(spacing: 3) {
                Text("게스트로 시작")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.paper)
                Text("기록이 이 기기에만 저장됩니다 · 나중에 로그인하면 계정으로 옮겨집니다")
                    .font(.system(size: 11))
                    .foregroundStyle(TL.faint)
            }
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
                Text("이메일 인증이 필요합니다")
                    .font(.tlTitle(20)).foregroundStyle(TL.paper)
                Text("\(email) 로 인증 메일을 보냈습니다.\n메일함에서 인증 링크를 누른 뒤 아래 버튼을 눌러주세요.")
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                run { try await account.confirmEmailVerified() }
            } label: {
                Text(working ? "확인 중…" : "인증 완료했어요")
            }
            .buttonStyle(TLPrimaryButtonStyle())
            .disabled(working)

            HStack(spacing: 18) {
                Button("인증 메일 재발송") {
                    run {
                        try await account.resendVerificationEmail()
                        await MainActor.run { errorMessage = "인증 메일을 다시 보냈습니다. 메일함(스팸함 포함)을 확인하세요." }
                    }
                }
                Button("다른 계정으로") {
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
