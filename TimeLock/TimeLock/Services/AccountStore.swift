//
//  AccountStore.swift
//  TimeLock
//
//  회원 계정: 이메일 회원가입/로그인, Google 로그인, Apple 로그인, 게스트 모드.
//  상점·벌점·예약·세션은 전부 ownerUserID로 계정에 귀속된다.
//
//  백엔드는 Firebase(Auth + Firestore)를 사용한다. 배포 전 준비:
//    1. Xcode에서 SPM 패키지 추가 — firebase-ios-sdk(FirebaseAuth, FirebaseFirestore), GoogleSignIn-iOS
//    2. Firebase 콘솔에서 iOS 앱 등록 후 GoogleService-Info.plist를 타깃에 추가
//    3. Info.plist에 Google 로그인용 URL Scheme(REVERSED_CLIENT_ID) 추가
//    4. Signing & Capabilities에 Sign in with Apple capability 추가
//  패키지가 없어도 빌드되도록 모든 Firebase 코드는 canImport 뒤에 격리했다.
//  Firebase가 없으면 '기기 내 계정'(오프라인 폴백)으로 동작한다 — 개발/시뮬레이터 테스트용.
//

import Foundation
import SwiftUI
import UIKit
import SwiftData
import AuthenticationServices
import CryptoKit
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// MARK: - 계정 모델

struct UserAccount: Codable, Equatable {
    enum Provider: String, Codable {
        case email, google, apple, guest
        var title: String {
            switch self {
            case .email:  return "이메일"
            case .google: return "Google"
            case .apple:  return "Apple"
            case .guest:  return "게스트"
            }
        }
    }
    let id: String
    var email: String?
    var displayName: String?
    var provider: Provider
}

enum AuthError: LocalizedError {
    case invalidEmail
    case weakPassword
    case wrongCredentials
    case duplicateEmail
    case providerUnavailable(String)
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:      return "이메일 형식이 올바르지 않습니다 — @를 포함해 입력하세요."
        case .weakPassword:      return "비밀번호가 8자 미만입니다 — 8자 이상으로 설정하세요."
        case .wrongCredentials:  return "이메일 또는 비밀번호가 맞지 않습니다."
        case .duplicateEmail:    return "이미 가입된 이메일입니다 — 로그인으로 전환하세요."
        case .providerUnavailable(let detail): return detail
        case .cancelled:         return ""
        case .unknown(let message): return message
        }
    }
}

enum DeleteAccountError: LocalizedError {
    case requiresRecentLogin
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .requiresRecentLogin:
            return "보안을 위해 다시 로그인한 뒤 삭제할 수 있습니다. 로그아웃 후 다시 로그인하고 삭제를 진행하세요."
        case .unknown(let message):
            return "계정 삭제에 실패했습니다 — \(message)"
        }
    }
}

// MARK: - AccountStore

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    /// 게스트 데이터의 고정 소유자 ID. 로그인하면 이 데이터가 계정으로 귀속된다.
    static let guestID = "guest"

    @Published private(set) var currentUser: UserAccount?
    /// 이메일 인증 대기 중인 주소. 값이 있으면 인증을 마쳐야 앱에 입장할 수 있다.
    @Published private(set) var pendingVerificationEmail: String?
    /// 계정 상태가 바뀔 때 AppState가 알람/파생값을 갱신하도록 훅
    var onUserChanged: (() -> Void)?

    private var modelContext: ModelContext?
    private let defaults = UserDefaults.standard
    private let sessionKey = "account.current"
    private var appleNonce: String?

    var currentUserID: String { currentUser?.id ?? "" }
    var isSignedIn: Bool { currentUser != nil }
    var isGuest: Bool { currentUser?.provider == .guest }

    /// Firebase SDK가 링크되어 있고 GoogleService-Info.plist로 초기화까지 끝났는가
    var backendActive: Bool {
        #if canImport(FirebaseCore)
        return FirebaseApp.app() != nil
        #else
        return false
        #endif
    }

    private init() {
        if let data = defaults.data(forKey: sessionKey),
           let user = try? JSONDecoder().decode(UserAccount.self, from: data) {
            currentUser = user
        }
    }

    // MARK: 초기화 & 바인딩

    /// 앱 시작 시 1회 — Firebase 구성 파일이 있으면 초기화하고 세션을 복원한다.
    func configureBackendIfAvailable() {
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil,
           Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        #endif
        #if canImport(FirebaseAuth)
        if backendActive {
            // 인증·비밀번호 재설정 등 Firebase 발송 메일을 한국어 템플릿으로
            Auth.auth().languageCode = "ko"
        }
        if backendActive, let user = Auth.auth().currentUser {
            let provider: UserAccount.Provider =
                user.providerData.contains { $0.providerID == "google.com" } ? .google :
                user.providerData.contains { $0.providerID == "apple.com" } ? .apple : .email
            // 이메일 미인증 계정은 세션 복원에서도 입장 차단 (인증 대기로 홀드)
            if provider == .email, !user.isEmailVerified {
                pendingVerificationEmail = user.email
                return
            }
            setUser(UserAccount(id: user.uid, email: user.email,
                                displayName: user.displayName, provider: provider))
        }
        #endif
    }

    func bind(context: ModelContext) {
        modelContext = context
        migrateLegacyOwnerless()
    }

    /// 계정 개념 도입 전에 만들어진(ownerUserID == "") 데이터를 게스트 소유로 귀속
    private func migrateLegacyOwnerless() {
        guard let context = modelContext else { return }
        var touched = false
        if let list = try? context.fetch(FetchDescriptor<Reservation>(predicate: #Predicate { $0.ownerUserID == "" })) {
            list.forEach { $0.ownerUserID = Self.guestID }; touched = touched || !list.isEmpty
        }
        if let list = try? context.fetch(FetchDescriptor<FocusSession>(predicate: #Predicate { $0.ownerUserID == "" })) {
            list.forEach { $0.ownerUserID = Self.guestID }; touched = touched || !list.isEmpty
        }
        if let list = try? context.fetch(FetchDescriptor<ScoreEvent>(predicate: #Predicate { $0.ownerUserID == "" })) {
            list.forEach { $0.ownerUserID = Self.guestID }; touched = touched || !list.isEmpty
        }
        if touched { try? context.save() }
    }

    // MARK: 이메일 회원가입 / 로그인

    func signUp(email: String, password: String, displayName: String) async throws {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), email.contains(".") else { throw AuthError.invalidEmail }
        guard password.count >= 8 else { throw AuthError.weakPassword }

        #if canImport(FirebaseAuth)
        if backendActive {
            do {
                let result = try await Auth.auth().createUser(withEmail: email, password: password)
                // 사용자 이름 저장 + 이메일 인증 메일 발송.
                // 인증을 마쳐야 입장 가능 — setUser 대신 인증 대기 상태로 홀드한다.
                if !name.isEmpty {
                    let change = result.user.createProfileChangeRequest()
                    change.displayName = name
                    try? await change.commitChanges()
                }
                try? await result.user.sendEmailVerification()
                pendingVerificationEmail = email
            } catch let error as NSError where error.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                throw AuthError.duplicateEmail
            } catch {
                throw AuthError.unknown(error.localizedDescription)
            }
            return
        }
        #endif
        let record = try LocalAccountVault.signUp(email: email, password: password)
        setUser(UserAccount(id: record.id, email: email,
                            displayName: name.isEmpty ? nil : name, provider: .email))
    }

    // MARK: 이메일 인증 상태

    /// 이메일 가입 계정의 인증 완료 여부. (소셜·게스트·오프라인 폴백은 해당 없음 → true)
    var isEmailVerified: Bool {
        #if canImport(FirebaseAuth)
        if backendActive, let user = Auth.auth().currentUser,
           currentUser?.provider == .email {
            return user.isEmailVerified
        }
        #endif
        return true
    }

    /// 인증 메일 재발송
    func resendVerificationEmail() async throws {
        #if canImport(FirebaseAuth)
        if backendActive, let user = Auth.auth().currentUser {
            try await user.sendEmailVerification()
            return
        }
        #endif
        throw AuthError.providerUnavailable("이메일 인증은 Firebase 연동 후 사용할 수 있습니다.")
    }

    /// 서버에서 최신 인증 상태를 다시 읽는다 (사용자가 메일 인증을 마친 뒤 새로고침용)
    func refreshEmailVerification() async {
        #if canImport(FirebaseAuth)
        if backendActive, let user = Auth.auth().currentUser {
            try? await user.reload()
            objectWillChange.send()
        }
        #endif
    }

    /// 인증 대기 화면의 '인증 완료했어요' — 서버에서 확인되면 그때 입장시킨다.
    func confirmEmailVerified() async throws {
        #if canImport(FirebaseAuth)
        guard backendActive, let user = Auth.auth().currentUser else {
            throw AuthError.providerUnavailable("네트워크 상태를 확인한 뒤 다시 시도하세요.")
        }
        try? await user.reload()
        guard user.isEmailVerified else {
            throw AuthError.unknown("아직 인증이 확인되지 않았습니다. 메일함에서 인증 링크를 누른 뒤 다시 시도하세요.")
        }
        pendingVerificationEmail = nil
        setUser(UserAccount(id: user.uid, email: user.email,
                            displayName: user.displayName, provider: .email))
        #else
        throw AuthError.providerUnavailable("이메일 인증은 Firebase 연동 후 사용할 수 있습니다.")
        #endif
    }

    /// 인증 대기를 취소하고 다른 계정으로 시작 (Firebase 세션도 정리)
    func cancelPendingVerification() {
        #if canImport(FirebaseAuth)
        if backendActive { try? Auth.auth().signOut() }
        #endif
        pendingVerificationEmail = nil
    }

    func signIn(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard email.contains("@") else { throw AuthError.invalidEmail }

        #if canImport(FirebaseAuth)
        if backendActive {
            let result: AuthDataResult
            do {
                result = try await Auth.auth().signIn(withEmail: email, password: password)
            } catch {
                throw AuthError.wrongCredentials
            }
            // 이메일 미인증 계정은 입장 차단 — 인증 대기 상태로 홀드
            guard result.user.isEmailVerified else {
                pendingVerificationEmail = email
                return
            }
            setUser(UserAccount(id: result.user.uid, email: email,
                                displayName: result.user.displayName, provider: .email))
            return
        }
        #endif
        let record = try LocalAccountVault.signIn(email: email, password: password)
        setUser(UserAccount(id: record.id, email: email, displayName: nil, provider: .email))
    }

    // MARK: Google 로그인

    func signInWithGoogle() async throws {
        #if canImport(GoogleSignIn) && canImport(FirebaseAuth)
        if backendActive {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                throw AuthError.providerUnavailable("GoogleService-Info.plist에 CLIENT_ID가 없습니다.")
            }
            guard let presenter = Self.topViewController() else {
                throw AuthError.unknown("로그인 화면을 띄울 수 없습니다. 다시 시도하세요.")
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                guard let idToken = result.user.idToken?.tokenString else {
                    throw AuthError.unknown("Google 인증 토큰을 받지 못했습니다. 다시 시도하세요.")
                }
                let credential = GoogleAuthProvider.credential(
                    withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
                let auth = try await Auth.auth().signIn(with: credential)
                setUser(UserAccount(id: auth.user.uid, email: auth.user.email,
                                    displayName: auth.user.displayName, provider: .google))
            } catch let error as NSError where error.domain == kGIDSignInErrorDomain
                        && error.code == GIDSignInError.canceled.rawValue {
                throw AuthError.cancelled
            } catch let error as AuthError {
                throw error
            } catch {
                throw AuthError.unknown(error.localizedDescription)
            }
            return
        }
        #endif
        throw AuthError.providerUnavailable(
            "Google 로그인은 Firebase 연동 후 사용할 수 있습니다. README의 '백엔드 연동' 절을 따라 설정하세요.")
    }

    // MARK: Apple 로그인 (App Store 심사 규정 4.8 — Google 로그인 제공 시 필수)

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.email, .fullName]
        #if canImport(FirebaseAuth)
        if backendActive {
            let nonce = Self.randomNonce()
            appleNonce = nonce
            request.nonce = Self.sha256Hex(nonce)
        }
        #endif
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                throw AuthError.cancelled
            }
            throw AuthError.unknown("Apple 로그인에 실패했습니다. Signing & Capabilities에 Sign in with Apple이 추가되어 있는지 확인하세요.")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AuthError.unknown("Apple 인증 정보를 읽지 못했습니다.")
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")

            #if canImport(FirebaseAuth)
            if backendActive,
               let tokenData = credential.identityToken,
               let token = String(data: tokenData, encoding: .utf8) {
                let firebaseCredential = OAuthProvider.appleCredential(
                    withIDToken: token, rawNonce: appleNonce, fullName: credential.fullName)
                let auth = try await Auth.auth().signIn(with: firebaseCredential)
                setUser(UserAccount(id: auth.user.uid,
                                    email: auth.user.email ?? credential.email,
                                    displayName: auth.user.displayName ?? (name.isEmpty ? nil : name),
                                    provider: .apple))
                return
            }
            #endif
            // 오프라인 폴백 — Apple의 기기 수준 식별자로 계정 구성
            setUser(UserAccount(id: "apple-\(credential.user)",
                                email: credential.email,
                                displayName: name.isEmpty ? nil : name,
                                provider: .apple))
        }
    }

    // MARK: 게스트 & 로그아웃

    func continueAsGuest() {
        setUser(UserAccount(id: Self.guestID, email: nil, displayName: "게스트", provider: .guest))
    }

    func signOut() {
        #if canImport(FirebaseAuth)
        if backendActive { try? Auth.auth().signOut() }
        #endif
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        currentUser = nil
        defaults.removeObject(forKey: sessionKey)
        onUserChanged?()
    }

    // MARK: 계정 삭제 (App Store 심사 규정 5.1.1(v) — 계정 생성 앱은 앱 내 삭제 필수)

    /// 계정을 삭제한다. 어떤 흔적도 남기지 않는 완전 삭제 정책.
    /// - 이 기기의 개인 데이터(예약·세션·점수·촬영본)를 즉시 완전 삭제
    /// - 서버(Firestore)의 사용자 문서와 점수 원장을 통째로 삭제
    /// - 인증 계정 자체를 삭제
    func deleteAccount() async throws {
        let uid = currentUserID
        guard !uid.isEmpty else { return }
        let isGuestAccount = currentUser?.provider == .guest

        // 1) 서버 데이터 완전 삭제 (Firebase 연동 시).
        //    하위 컬렉션은 자동 삭제되지 않으므로 점수 원장 문서를 먼저 지운 뒤 사용자 문서 삭제.
        //    (인증 계정을 지우기 전에 수행 — 이후엔 보안 규칙상 쓰기 권한이 사라진다)
        #if canImport(FirebaseFirestore)
        if backendActive, !isGuestAccount {
            let db = Firestore.firestore()
            let userDoc = db.collection("users").document(uid)
            // 참여 중인 그룹에서 내 멤버 문서(닉네임·점수)를 지운다 —
            // 남기면 계정이 사라진 뒤에도 랭킹에 유령 회원으로 계속 표시된다.
            if let groupIDs = (try? await userDoc.getDocument())?.data()?["groupIDs"] as? [String] {
                for roomID in groupIDs {
                    let roomRef = db.collection("groups").document(roomID)
                    try? await roomRef.collection("members").document(uid).delete()
                    try? await roomRef.updateData(["memberCount": FieldValue.increment(Int64(-1))])
                }
            }
            if let snapshot = try? await userDoc.collection("scoreEvents").getDocuments() {
                for doc in snapshot.documents { try? await doc.reference.delete() }
            }
            // 크로스 기기 동기화용 예약 사본도 함께 삭제 (안 지우면 계정 삭제 후에도 클라우드에 남음)
            if let snapshot = try? await userDoc.collection("reservations").getDocuments() {
                for doc in snapshot.documents { try? await doc.reference.delete() }
            }
            try? await userDoc.delete()
        }
        #endif

        // 2) 인증 계정 삭제 (최근 로그인 필요 시 재로그인 요청)
        #if canImport(FirebaseAuth)
        if backendActive, let fbUser = Auth.auth().currentUser {
            do {
                try await fbUser.delete()
            } catch let error as NSError where error.code == AuthErrorCode.requiresRecentLogin.rawValue {
                throw DeleteAccountError.requiresRecentLogin
            } catch {
                throw DeleteAccountError.unknown(error.localizedDescription)
            }
        }
        #endif
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif

        // 3) 이 기기의 개인 데이터 완전 삭제 (예약·세션·점수 + 촬영본 파일)
        deleteLocalData(ownerID: uid)
        LocalAccountVault.remove(id: uid)   // 오프라인 폴백 계정도 제거

        // 4) 세션 종료 → 인증 화면으로 복귀 (onUserChanged가 라우팅)
        currentUser = nil
        defaults.removeObject(forKey: sessionKey)
        onUserChanged?()
    }

    /// 특정 소유자의 로컬 데이터(예약·세션·점수)와 촬영본 파일을 모두 삭제
    private func deleteLocalData(ownerID owner: String) {
        guard let context = modelContext else { return }
        if let list = try? context.fetch(FetchDescriptor<FocusSession>(predicate: #Predicate { $0.ownerUserID == owner })) {
            list.forEach { session in
                SessionStorage.deleteFiles(of: session)   // 촬영본·썸네일 파일 삭제
                context.delete(session)
            }
        }
        if let list = try? context.fetch(FetchDescriptor<Reservation>(predicate: #Predicate { $0.ownerUserID == owner })) {
            list.forEach { context.delete($0) }
        }
        if let list = try? context.fetch(FetchDescriptor<ScoreEvent>(predicate: #Predicate { $0.ownerUserID == owner })) {
            list.forEach { context.delete($0) }
        }
        try? context.save()
    }

    // MARK: 내부

    private func setUser(_ user: UserAccount) {
        currentUser = user
        if let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: sessionKey)
        }
        // 게스트 데이터는 로그인 계정과 철저히 분리한다(#16) — 절대 흡수하지 않는다.
        // 게스트로 쌓은 기록은 'guest' 소유로 남는 최하위 데이터이며(유실돼도 복구 불가),
        // 로그인 계정은 오직 자기 소유(ownerUserID) 데이터만 보고 다룬다. (안드로이드와 동일)
        onUserChanged?()
    }

    // MARK: 클라우드 미러 (상점·벌점 백업)

    /// 점수 이벤트를 사용자별 Firestore 문서로 백업한다. 실패해도 로컬 기록이 원본.
    func mirror(event: ScoreEvent) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.id)
            .collection("scoreEvents").document(event.id.uuidString.lowercased())
            .setData([
                "type": event.typeRaw,
                "points": event.points,
                "intensity": event.intensityRaw,
                "timestamp": event.timestamp,
                "note": event.note ?? "",
                "sessionID": event.sessionID?.uuidString ?? ""
            ], merge: true)
        db.collection("users").document(user.id).setData([
            "email": user.email ?? "",
            "displayName": user.displayName ?? "",
            "lastActiveAt": Date()
        ], merge: true)
        #endif
    }

    // MARK: 크로스 기기 동기화 — 점수 원장 · 개인 예약 · 멤버십

    /// 앱 시작·복귀·로그인 시 호출되는 통합 동기화.
    /// 같은 계정이면 iOS·안드로이드 어디서든 예약/점수/멤버십이 일치하게 만든다.
    func syncFromCloud() async {
        await syncScoreEventsFromCloud()
        await syncReservationsFromCloud()
        await syncSessionSummariesFromCloud()
        await syncBonusStateFromCloud()
        await syncMembershipFromCloud()
        await syncHomeGoalFromCloud()
    }

    // 보너스 지급 dedup 상태 동기화 — 세션 이력을 동기화하면 새 기기에서 streak·완주수가
    // 복원되므로, 슬롯/해제 보너스가 이미 지급됐다는 사실도 함께 옮겨야 중복 지급되지 않는다.
    func mirrorSlotBonusTier(_ tier: Int) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        Firestore.firestore().collection("users").document(user.id)
            .setData(["slotBonusAwardedTier": tier], merge: true)
        #endif
    }
    func mirrorUnlockBonusAwarded() {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        Firestore.firestore().collection("users").document(user.id)
            .setData(["unlockBonusAwarded": true], merge: true)
        #endif
    }
    private func syncBonusStateFromCloud() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        let uid = user.id
        guard let doc = try? await Firestore.firestore()
            .collection("users").document(uid).getDocument() else { return }
        let data = doc.data() ?? [:]
        let d = UserDefaults.standard
        // 양방향 — 큰 쪽이 이긴다. 기존 사용자(클라우드에 상태 없음)는 로컬을 올려 다음 기기가 받게 한다.
        let slotKey = "slotBonus.awardedTier.\(uid)"
        let localTier = d.integer(forKey: slotKey)
        let cloudTier = data["slotBonusAwardedTier"] as? Int ?? 0
        if cloudTier > localTier { d.set(cloudTier, forKey: slotKey) }
        else if localTier > cloudTier { mirrorSlotBonusTier(localTier) }

        let unlockKey = "unlockBonus.awarded.\(uid)"
        let localUnlock = d.bool(forKey: unlockKey)
        let cloudUnlock = data["unlockBonusAwarded"] as? Bool ?? false
        if cloudUnlock, !localUnlock { d.set(true, forKey: unlockKey) }
        else if localUnlock, !cloudUnlock { mirrorUnlockBonusAwarded() }
        #endif
    }

    /// 홈 다짐(목표) 문구 업로드 — 홈 화면 편집 저장 시 호출
    func mirrorHomeGoal(_ text: String) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        Firestore.firestore().collection("users").document(user.id).setData([
            "homeGoal": text,
            "homeGoalUpdatedAt": Int64(Date.now.timeIntervalSince1970 * 1000),
        ], merge: true)
        #endif
    }

    /// 클라우드 다짐 문구 읽기 — updatedAt이 더 최신이면 로컬(UserDefaults)을 덮어쓴다
    private func syncHomeGoalFromCloud() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        let uid = user.id
        guard let doc = try? await Firestore.firestore().collection("users").document(uid).getDocument(),
              let cloudText = doc.data()?["homeGoal"] as? String else { return }
        let cloudUpdated = (doc.data()?["homeGoalUpdatedAt"] as? Int64) ?? 0
        let goalKey = "homeGoal.\(uid)"
        let goalUpdatedKey = "homeGoalUpdatedAt.\(uid)"
        let localUpdated = Int64(UserDefaults.standard.double(forKey: goalUpdatedKey) * 1000)
        if cloudUpdated > localUpdated {
            UserDefaults.standard.set(cloudText, forKey: goalKey)
            UserDefaults.standard.set(Double(cloudUpdated) / 1000, forKey: goalUpdatedKey)
        } else if localUpdated > cloudUpdated {
            mirrorHomeGoal(UserDefaults.standard.string(forKey: goalKey) ?? "")
        }
        #endif
    }

    /// 클라우드 원장 내려받기 — 다른 기기(안드로이드 포함)에서 쌓인 점수 이벤트를 로컬에 병합한다.
    /// mirror(업로드)와 짝을 이루는 다운로드 절반. 이벤트 ID(UUID) 기준으로 중복 없이 합쳐진다.
    private func syncScoreEventsFromCloud() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest,
              let context = modelContext else { return }
        let uid = user.id
        guard let snapshot = try? await Firestore.firestore()
            .collection("users").document(uid).collection("scoreEvents").getDocuments()
        else { return }

        let existing = Set(((try? context.fetch(FetchDescriptor<ScoreEvent>(
            predicate: #Predicate { $0.ownerUserID == uid }))) ?? []).map(\.id))

        var added = false
        for doc in snapshot.documents {
            guard let id = UUID(uuidString: doc.documentID), !existing.contains(id) else { continue }
            let data = doc.data()
            guard let typeRaw = data["type"] as? String,
                  let points = data["points"] as? Int else { continue }
            let event = ScoreEvent(
                type: ScoreEventType(rawValue: typeRaw) ?? .complete,
                points: points,
                sessionID: (data["sessionID"] as? String).flatMap(UUID.init(uuidString:)),
                intensity: Intensity(rawValue: data["intensity"] as? String ?? "") ?? .spicy,
                note: (data["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                ownerUserID: uid)
            event.id = id
            // 플랫폼별 저장 형식 차이 수용: iOS는 Timestamp, 안드로이드는 밀리초 정수
            if let ts = data["timestamp"] as? Timestamp {
                event.timestamp = ts.dateValue()
            } else if let ms = data["timestamp"] as? Double {
                event.timestamp = Date(timeIntervalSince1970: ms / 1000)
            } else if let ms = data["timestamp"] as? Int64 {
                event.timestamp = Date(timeIntervalSince1970: Double(ms) / 1000)
            }
            context.insert(event)
            added = true
        }
        if added { try? context.save() }
        #endif
    }

    /// 개인 예약 1건 클라우드 업로드 (그룹 예약은 GroupStore가 방 문서에서 재생성하므로 제외).
    /// 편집 화면 저장·삭제 시와 병합 중 로컬이 최신일 때 호출된다.
    func mirrorReservation(_ r: Reservation) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest,
              r.groupID == nil else { return }
        func ms(_ date: Date?) -> Any { date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull() }
        Firestore.firestore().collection("users").document(user.id)
            .collection("reservations").document(r.id.uuidString.lowercased())
            .setData([
                "name": r.name, "tag": r.tag,
                "startMinute": r.startMinute, "durationMinutes": r.durationMinutes,
                "repeatWeekdays": r.repeatWeekdays,
                "oneOffDate": ms(r.oneOffDate),
                "createdAt": ms(r.createdAt),
                "accountableFrom": ms(r.accountableFrom),
                "isActive": r.isActive,
                "updatedAt": ms(r.updatedAt ?? r.createdAt),
            ], merge: true)
        #endif
    }

    /// 개인 예약 양방향 병합 — updatedAt이 최신인 쪽이 이긴다.
    /// 클라우드가 최신 → 로컬 덮어쓰기 / 로컬이 최신·클라우드에 없음 → 업로드.
    private func syncReservationsFromCloud() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest,
              let context = modelContext else { return }
        let uid = user.id
        guard let snapshot = try? await Firestore.firestore()
            .collection("users").document(uid).collection("reservations").getDocuments()
        else { return }

        func ms(_ any: Any?) -> Date? {
            (any as? Int64).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }

        let locals = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.ownerUserID == uid }))) ?? []
        var localByID = [String: Reservation]()
        for r in locals where r.groupID == nil { localByID[r.id.uuidString.lowercased()] = r }

        var cloudIDs = Set<String>()
        var touched = false
        for doc in snapshot.documents {
            let key = doc.documentID.lowercased()
            cloudIDs.insert(key)
            let data = doc.data()
            let cloudUpdated = ms(data["updatedAt"]) ?? .distantPast
            if let local = localByID[key] {
                let localUpdated = local.updatedAt ?? local.createdAt
                if cloudUpdated > localUpdated {
                    local.name = data["name"] as? String ?? local.name
                    local.tag = data["tag"] as? String ?? local.tag
                    local.startMinute = data["startMinute"] as? Int ?? local.startMinute
                    local.durationMinutes = data["durationMinutes"] as? Int ?? local.durationMinutes
                    local.repeatWeekdays = data["repeatWeekdays"] as? [Int] ?? local.repeatWeekdays
                    local.oneOffDate = ms(data["oneOffDate"])
                    local.accountableFrom = ms(data["accountableFrom"]) ?? local.accountableFrom
                    local.isActive = data["isActive"] as? Bool ?? local.isActive
                    local.updatedAt = cloudUpdated
                    touched = true
                } else if localUpdated > cloudUpdated {
                    mirrorReservation(local)
                }
            } else if let id = UUID(uuidString: key), let name = data["name"] as? String {
                // 다른 기기에서 만든 예약 — 로컬에 생성
                let r = Reservation(
                    name: name, tag: data["tag"] as? String ?? "",
                    startMinute: data["startMinute"] as? Int ?? 0,
                    durationMinutes: data["durationMinutes"] as? Int ?? 60,
                    repeatWeekdays: data["repeatWeekdays"] as? [Int] ?? [],
                    oneOffDate: ms(data["oneOffDate"]),
                    ownerUserID: uid)
                r.id = id
                r.createdAt = ms(data["createdAt"]) ?? r.createdAt
                r.accountableFrom = ms(data["accountableFrom"])
                r.isActive = data["isActive"] as? Bool ?? true
                r.updatedAt = ms(data["updatedAt"])
                context.insert(r)
                touched = true
            }
        }
        // 클라우드에 아직 없는 로컬 개인 예약 → 최초 업로드 (기존 사용자 마이그레이션)
        for (key, local) in localByID where !cloudIDs.contains(key) {
            mirrorReservation(local)
        }
        if touched { try? context.save() }
        #endif
    }

    // MARK: 세션 요약 동기화 — 기기 변경 시 진척 보존
    // 완료된 세션의 '요약'(영상 제외: 활동명·태그·강도·시각·성공여부)을 계정 클라우드에 미러한다.
    // 새 기기는 이 요약을 내려받아 연속 달성일·미친맛 해제·활동 슬롯·성공 캘린더를 이력 기준으로
    // 다시 계산한다 → 기기를 바꿔도 0으로 리셋되지 않는다. 영상 파일 자체는 기기 로컬에만 남는다.

    /// 완료 세션 1건의 요약을 클라우드에 미러 (best-effort, 영상 제외). outcome이 있어야 올린다.
    func mirrorSession(_ s: FocusSession) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest,
              s.outcomeRaw != nil else { return }
        func ms(_ date: Date?) -> Any { date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull() }
        Firestore.firestore().collection("users").document(user.id)
            .collection("sessionSummaries").document(s.id.uuidString.lowercased())
            .setData([
                "activityName": s.activityName, "tag": s.tag,
                "intensity": s.intensityRaw,
                "scheduledAt": ms(s.scheduledAt),
                "startedAt": ms(s.startedAt),
                "endedAt": ms(s.endedAt),
                "targetSeconds": s.targetSeconds,
                "recordedSeconds": s.recordedSeconds,
                "outcome": s.outcomeRaw ?? "",
                "reservationID": s.reservationID?.uuidString ?? "",
                "updatedAt": ms(s.endedAt ?? .now),
            ], merge: true)
        #endif
    }

    /// 세션 요약 병합 — 다른 기기(안드로이드 포함)에서 쌓인 완료 세션을 로컬에 생성한다(영상 없이).
    /// 로컬에 이미 있는 세션(내 영상 포함 가능)은 절대 덮어쓰지 않는다 → 영상 참조 보존.
    private func syncSessionSummariesFromCloud() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest,
              let context = modelContext else { return }
        let uid = user.id
        guard let snapshot = try? await Firestore.firestore()
            .collection("users").document(uid).collection("sessionSummaries").getDocuments()
        else { return }

        func ms(_ any: Any?) -> Date? {
            (any as? Int64).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }

        let locals = (try? context.fetch(FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.ownerUserID == uid }))) ?? []
        let localIDs = Set(locals.map { $0.id.uuidString.lowercased() })

        var cloudIDs = Set<String>()
        var touched = false
        for doc in snapshot.documents {
            let key = doc.documentID.lowercased()
            cloudIDs.insert(key)
            if localIDs.contains(key) { continue }   // 로컬 우선 — 영상 참조 보존
            let data = doc.data()
            guard let id = UUID(uuidString: key),
                  let outcome = data["outcome"] as? String, !outcome.isEmpty,
                  let intensityRaw = data["intensity"] as? String else { continue }
            let s = FocusSession(
                activityName: data["activityName"] as? String ?? "",
                tag: data["tag"] as? String ?? "",
                intensity: Intensity(rawValue: intensityRaw) ?? .spicy,
                scheduledAt: ms(data["scheduledAt"]),
                targetSeconds: data["targetSeconds"] as? Int ?? 0,
                reservationID: (data["reservationID"] as? String).flatMap { UUID(uuidString: $0) },
                ownerUserID: uid)
            s.id = id
            s.startedAt = ms(data["startedAt"])
            s.endedAt = ms(data["endedAt"])
            s.recordedSeconds = data["recordedSeconds"] as? Int ?? 0
            s.outcomeRaw = outcome
            context.insert(s)
            touched = true
        }
        // 클라우드에 아직 없는 로컬 완료 세션 → 최초 업로드 (기존 사용자 이력 마이그레이션)
        for s in locals where s.outcomeRaw != nil && !cloudIDs.contains(s.id.uuidString.lowercased()) {
            mirrorSession(s)
        }
        if touched { try? context.save() }
        #endif
    }

    /// 구독 상태 클라우드 기록 — 반대 플랫폼(안드로이드)에서도 멤버십이 인정되도록.
    func mirrorMembership(expiresAt: Date, platform: String) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        Firestore.firestore().collection("users").document(user.id).setData([
            "proExpiresAt": Int64(expiresAt.timeIntervalSince1970 * 1000),
            "proPlatform": platform,
        ], merge: true)
        #endif
    }

    /// 클라우드 구독 상태 읽기 → SubscriptionManager에 반영 (스토어 구독 ∨ 클라우드 유효 = Pro)
    private func syncMembershipFromCloud() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else {
            SubscriptionManager.shared.cloudProUntil = nil
            return
        }
        let doc = try? await Firestore.firestore()
            .collection("users").document(user.id).getDocument()
        let until = (doc?.data()?["proExpiresAt"] as? Int64)
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
        SubscriptionManager.shared.cloudProUntil = until
        #endif
    }

    // MARK: 유틸

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.keyWindow?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Firebase Apple 로그인용 nonce. SystemRandomNumberGenerator는 암호학적으로 안전하다.
    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in charset[Int.random(in: 0..<charset.count)] })
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 기기 내 계정 저장소 (Firebase 미연동 시 폴백)
//
// 개발·시뮬레이터 테스트용. 비밀번호는 계정별 솔트 + SHA256 해시로 저장하며
// 기기 밖으로 나가지 않는다. 배포 빌드는 반드시 Firebase를 연동할 것.

private enum LocalAccountVault {
    struct Record: Codable {
        let id: String
        let email: String
        let salt: String
        let passwordHash: String
    }

    private static let key = "account.localVault"

    private static func load() -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records
    }

    private static func save(_ records: [Record]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func hash(password: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + password).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func signUp(email: String, password: String) throws -> Record {
        var records = load()
        guard !records.contains(where: { $0.email == email }) else { throw AuthError.duplicateEmail }
        let salt = UUID().uuidString
        let record = Record(id: "local-\(UUID().uuidString)", email: email,
                            salt: salt, passwordHash: hash(password: password, salt: salt))
        records.append(record)
        save(records)
        return record
    }

    static func signIn(email: String, password: String) throws -> Record {
        guard let record = load().first(where: { $0.email == email }),
              record.passwordHash == hash(password: password, salt: record.salt) else {
            throw AuthError.wrongCredentials
        }
        return record
    }

    /// 계정 삭제 시 오프라인 폴백 레코드 제거
    static func remove(id: String) {
        var records = load()
        let before = records.count
        records.removeAll { $0.id == id }
        if records.count != before { save(records) }
    }
}
