package com.singlemarks.angrymoti.services

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.EmailAuthProvider
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.firestore.FirebaseFirestore
import com.singlemarks.angrymoti.data.ScoreEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.tasks.await

/**
 * 인증 — iOS AccountStore와 동일 전략:
 * google-services.json이 없으면 Firebase 없이 '기기 내 계정(게스트)'으로 동작한다.
 * 같은 Firebase 프로젝트(timelock-eba85)를 쓰므로 iOS와 계정·점수가 공유된다.
 */
object AccountStore {
    data class UserInfo(
        val uid: String,
        val name: String?,
        val email: String?,
        val provider: String,   // "guest" | "email" | "google"
        val emailVerified: Boolean,
    )

    val user = MutableStateFlow<UserInfo?>(null)
    val pendingVerificationEmail = MutableStateFlow<String?>(null)

    val firebaseAvailable: Boolean
        get() = FirebaseApp.getApps(appContext).isNotEmpty()

    private lateinit var appContext: Context

    fun init(context: Context) {
        appContext = context.applicationContext
        try { FirebaseApp.initializeApp(appContext) } catch (_: Exception) {}
        if (firebaseAvailable) {
            FirebaseAuth.getInstance().setLanguageCode("ko")
            FirebaseAuth.getInstance().currentUser?.let { u ->
                if (u.isEmailVerified || u.providerData.any { it.providerId == "google.com" }) {
                    user.value = UserInfo(u.uid, u.displayName, u.email, providerOf(u.providerData.map { it.providerId }), u.isEmailVerified)
                }
            }
        }
    }

    private fun providerOf(ids: List<String>) = when {
        ids.contains("google.com") -> "google"
        else -> "email"
    }

    val currentUserID: String get() = user.value?.uid ?: "guest"
    val isSignedIn: Boolean get() = user.value != null

    fun continueAsGuest(name: String?) {
        com.singlemarks.angrymoti.data.Prefs.guestName = name
        user.value = UserInfo("guest", name ?: "게스트", null, "guest", true)
    }

    // MARK: 이메일

    suspend fun signUpEmail(email: String, password: String, name: String) {
        require(firebaseAvailable) { "이메일 가입은 Firebase 연동 후 사용할 수 있습니다." }
        val auth = FirebaseAuth.getInstance()
        val result = auth.createUserWithEmailAndPassword(email, password).await()
        result.user?.updateProfile(
            com.google.firebase.auth.UserProfileChangeRequest.Builder().setDisplayName(name).build()
        )?.await()
        result.user?.sendEmailVerification()?.await()
        pendingVerificationEmail.value = email
    }

    suspend fun signInEmail(email: String, password: String) {
        require(firebaseAvailable) { "이메일 로그인은 Firebase 연동 후 사용할 수 있습니다." }
        val auth = FirebaseAuth.getInstance()
        val result = auth.signInWithEmailAndPassword(email, password).await()
        val u = result.user ?: error("로그인 실패")
        if (!u.isEmailVerified) {
            u.sendEmailVerification()
            pendingVerificationEmail.value = email
            return
        }
        user.value = UserInfo(u.uid, u.displayName, u.email, "email", true)
        syncScoreEventsFromCloud()   // 다른 기기에서 쌓인 점수 즉시 병합
    }

    /** 인증 메일 클릭 후 '인증 완료' — 새로고침해서 확인 */
    suspend fun confirmEmailVerified(): Boolean {
        val u = FirebaseAuth.getInstance().currentUser ?: return false
        u.reload().await()
        if (u.isEmailVerified) {
            pendingVerificationEmail.value = null
            user.value = UserInfo(u.uid, u.displayName, u.email, "email", true)
            syncScoreEventsFromCloud()   // 다른 기기에서 쌓인 점수 즉시 병합
            return true
        }
        return false
    }

    suspend fun resendVerificationEmail() {
        FirebaseAuth.getInstance().currentUser?.sendEmailVerification()?.await()
    }

    fun cancelPendingVerification() {
        pendingVerificationEmail.value = null
        if (firebaseAvailable) FirebaseAuth.getInstance().signOut()
    }

    // MARK: Google (ID 토큰은 UI 계층에서 Google Sign-In으로 획득)

    suspend fun signInGoogle(idToken: String) {
        require(firebaseAvailable) { "Google 로그인은 Firebase 연동 후 사용할 수 있습니다." }
        val credential = GoogleAuthProvider.getCredential(idToken, null)
        val result = FirebaseAuth.getInstance().signInWithCredential(credential).await()
        val u = result.user ?: error("로그인 실패")
        user.value = UserInfo(u.uid, u.displayName, u.email, "google", true)
        syncScoreEventsFromCloud()   // 다른 기기에서 쌓인 점수 즉시 병합
    }

    fun signOut() {
        if (firebaseAvailable) FirebaseAuth.getInstance().signOut()
        user.value = null
    }

    /** 계정 삭제 — 서버(원장 미러 포함)·인증 사용자 즉시 완전 삭제. 로컬 데이터는 호출측에서 지운다. */
    suspend fun deleteAccount() {
        val uid = currentUserID
        if (firebaseAvailable && uid != "guest") {
            val fs = FirebaseFirestore.getInstance()
            // 참여 중인 그룹방에서 내 멤버 문서 제거 (유령 멤버 방지 — iOS와 동일)
            runCatching {
                val userDoc = fs.collection("users").document(uid).get().await()
                @Suppress("UNCHECKED_CAST")
                val groupIDs = userDoc.get("groupIDs") as? List<String> ?: emptyList()
                for (roomID in groupIDs) {
                    val roomRef = fs.collection("groups").document(roomID)
                    runCatching { roomRef.collection("members").document(uid).delete().await() }
                    runCatching {
                        roomRef.update("memberCount",
                            com.google.firebase.firestore.FieldValue.increment(-1)).await()
                    }
                }
            }
            runCatching {
                val docs = fs.collection("users").document(uid).collection("scoreEvents").get().await()
                for (d in docs.documents) d.reference.delete().await()
                fs.collection("users").document(uid).delete().await()
            }
            runCatching { FirebaseAuth.getInstance().currentUser?.delete()?.await() }
        }
        user.value = null
    }

    /** 클라우드 원장 내려받기 — 다른 기기(iOS 포함)에서 쌓인 점수 이벤트를 로컬 Room에 병합한다.
     *  mirror(업로드)와 짝을 이루는 다운로드 절반. 이벤트 ID 기준으로 중복 없이 합쳐진다. */
    suspend fun syncScoreEventsFromCloud() {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        val snapshot = runCatching {
            FirebaseFirestore.getInstance()
                .collection("users").document(uid).collection("scoreEvents").get().await()
        }.getOrNull() ?: return

        val db = com.singlemarks.angrymoti.data.AppDb.get(appContext)
        // iOS는 대문자 UUID로 저장하므로 비교는 소문자 통일
        val existing = db.scores().ids(uid).map { it.lowercase() }.toSet()
        for (doc in snapshot.documents) {
            if (doc.id.lowercase() in existing) continue
            val typeRaw = doc.getString("type") ?: continue
            val points = doc.getLong("points")?.toInt() ?: continue
            // 플랫폼별 저장 형식 차이 수용: iOS는 Timestamp, 안드로이드는 밀리초 정수
            val timestamp = when (val ts = doc.get("timestamp")) {
                is com.google.firebase.Timestamp -> ts.toDate().time
                is Number -> ts.toLong()
                else -> System.currentTimeMillis()
            }
            db.scores().insert(com.singlemarks.angrymoti.data.ScoreEvent(
                id = doc.id.lowercase(), ownerUserID = uid,
                typeRaw = typeRaw, points = points,
                sessionID = doc.getString("sessionID")?.takeIf { it.isNotEmpty() }?.lowercase(),
                intensityRaw = doc.getString("intensity") ?: "spicy",
                timestamp = timestamp,
                note = doc.getString("note")?.takeIf { it.isNotEmpty() },
            ))
        }
    }

    /** 점수 이벤트 클라우드 미러 (best-effort — 실패해도 로컬 원장이 기준) */
    fun mirror(event: ScoreEvent) {
        if (!firebaseAvailable || event.ownerUserID == "guest") return
        runCatching {
            FirebaseFirestore.getInstance()
                .collection("users").document(event.ownerUserID)
                .collection("scoreEvents").document(event.id)
                .set(
                    mapOf(
                        "type" to event.typeRaw, "points" to event.points,
                        "sessionID" to event.sessionID, "intensity" to event.intensityRaw,
                        "timestamp" to event.timestamp, "note" to event.note,
                    )
                )
        }
    }

    suspend fun reauthenticateEmail(password: String) {
        val u = FirebaseAuth.getInstance().currentUser ?: return
        val email = u.email ?: return
        u.reauthenticate(EmailAuthProvider.getCredential(email, password)).await()
    }
}
