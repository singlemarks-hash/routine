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
        if backendActive, let user = Auth.auth().currentUser {
            let provider: UserAccount.Provider =
                user.providerData.contains { $0.providerID == "google.com" } ? .google :
                user.providerData.contains { $0.providerID == "apple.com" } ? .apple : .email
            setUser(UserAccount(id: user.uid, email: user.email,
                                displayName: user.displayName, provider: provider),
                    adoptGuestData: false)
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

    func signUp(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard email.contains("@"), email.contains(".") else { throw AuthError.invalidEmail }
        guard password.count >= 8 else { throw AuthError.weakPassword }

        #if canImport(FirebaseAuth)
        if backendActive {
            do {
                let result = try await Auth.auth().createUser(withEmail: email, password: password)
                setUser(UserAccount(id: result.user.uid, email: email, displayName: nil, provider: .email))
            } catch let error as NSError where error.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                throw AuthError.duplicateEmail
            } catch {
                throw AuthError.unknown(error.localizedDescription)
            }
            return
        }
        #endif
        let record = try LocalAccountVault.signUp(email: email, password: password)
        setUser(UserAccount(id: record.id, email: email, displayName: nil, provider: .email))
    }

    func signIn(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard email.contains("@") else { throw AuthError.invalidEmail }

        #if canImport(FirebaseAuth)
        if backendActive {
            do {
                let result = try await Auth.auth().signIn(withEmail: email, password: password)
                setUser(UserAccount(id: result.user.uid, email: email,
                                    displayName: result.user.displayName, provider: .email))
            } catch {
                throw AuthError.wrongCredentials
            }
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
        setUser(UserAccount(id: Self.guestID, email: nil, displayName: "게스트", provider: .guest),
                adoptGuestData: false)
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

    /// 계정을 삭제한다.
    /// - 이 기기의 개인 데이터(예약·세션·점수·촬영본)를 즉시 완전 삭제
    /// - 운영자 원장(서버)은 식별정보를 끊고(익명화) 3개월 보존 후 서버 배치로 파기
    ///   → 개인정보가 아닌 통계로만 남으므로 PIPA·App Store 모두 안전
    /// - 인증 계정 자체를 삭제
    func deleteAccount() async throws {
        let uid = currentUserID
        guard !uid.isEmpty else { return }
        let isGuestAccount = currentUser?.provider == .guest

        // 1) 서버 원장 익명화 + 3개월 보존/파기 마커 (Firebase 연동 시)
        //    개인 식별정보(email·displayName)를 제거하고 purgeAfter 이후 서버 배치가 파기한다.
        #if canImport(FirebaseFirestore)
        if backendActive, !isGuestAccount {
            let purgeAfter = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
            try? await Firestore.firestore().collection("users").document(uid).setData([
                "email": FieldValue.delete(),
                "displayName": FieldValue.delete(),
                "anonymized": true,
                "deletedAt": Date(),
                "purgeAfter": purgeAfter
            ], merge: true)
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

    private func setUser(_ user: UserAccount, adoptGuestData adopt: Bool = true) {
        currentUser = user
        if let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: sessionKey)
        }
        if adopt, user.provider != .guest { adoptGuestData(into: user.id) }
        onUserChanged?()
    }

    /// 게스트로 쌓은 예약·세션·점수를 방금 로그인한 계정으로 귀속
    private func adoptGuestData(into userID: String) {
        guard let context = modelContext else { return }
        let guest = Self.guestID
        var touched = false
        if let list = try? context.fetch(FetchDescriptor<Reservation>(predicate: #Predicate { $0.ownerUserID == guest })) {
            list.forEach { $0.ownerUserID = userID }; touched = touched || !list.isEmpty
        }
        if let list = try? context.fetch(FetchDescriptor<FocusSession>(predicate: #Predicate { $0.ownerUserID == guest })) {
            list.forEach { $0.ownerUserID = userID }; touched = touched || !list.isEmpty
        }
        if let list = try? context.fetch(FetchDescriptor<ScoreEvent>(predicate: #Predicate { $0.ownerUserID == guest })) {
            list.forEach { $0.ownerUserID = userID }; touched = touched || !list.isEmpty
        }
        if touched { try? context.save() }
    }

    // MARK: 클라우드 미러 (상점·벌점 백업)

    /// 점수 이벤트를 사용자별 Firestore 문서로 백업한다. 실패해도 로컬 기록이 원본.
    func mirror(event: ScoreEvent) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let user = currentUser, user.provider != .guest else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.id)
            .collection("scoreEvents").document(event.id.uuidString)
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
