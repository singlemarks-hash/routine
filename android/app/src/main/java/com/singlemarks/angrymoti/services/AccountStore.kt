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

    /** 홈 다짐(목표) 문구 — 편집·클라우드 병합·계정 전환이 모두 이 값을 갱신하고 홈이 구독한다.
     *  (예전엔 홈이 Prefs를 1회만 읽어 계정 전환·동기화가 화면에 반영되지 않았다) */
    val homeGoal = MutableStateFlow("")

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
        syncFromCloud()   // 다른 기기에서 쌓인 예약·점수·멤버십 즉시 병합
    }

    /** 인증 메일 클릭 후 '인증 완료' — 새로고침해서 확인 */
    suspend fun confirmEmailVerified(): Boolean {
        val u = FirebaseAuth.getInstance().currentUser ?: return false
        u.reload().await()
        if (u.isEmailVerified) {
            pendingVerificationEmail.value = null
            user.value = UserInfo(u.uid, u.displayName, u.email, "email", true)
            syncFromCloud()   // 다른 기기에서 쌓인 예약·점수·멤버십 즉시 병합
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
        syncFromCloud()   // 다른 기기에서 쌓인 예약·점수·멤버십 즉시 병합
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
            }
            // 크로스 기기 동기화용 예약 사본도 함께 삭제 (안 지우면 계정 삭제 후에도 클라우드에 남음)
            runCatching {
                val docs = fs.collection("users").document(uid).collection("reservations").get().await()
                for (d in docs.documents) d.reference.delete().await()
            }
            runCatching { fs.collection("users").document(uid).delete().await() }
            runCatching { FirebaseAuth.getInstance().currentUser?.delete()?.await() }
        }
        user.value = null
    }

    // MARK: 크로스 기기 동기화 — 점수 원장 · 개인 예약 · 멤버십

    /** 앱 시작·복귀·로그인 시 호출되는 통합 동기화.
     *  같은 계정이면 iOS·안드로이드 어디서든 예약/점수/멤버십/다짐 문구가 일치하게 만든다. */
    suspend fun syncFromCloud() {
        syncScoreEventsFromCloud()
        syncReservationsFromCloud()
        syncSessionSummariesFromCloud()
        syncBonusStateFromCloud()
        syncMembershipFromCloud()
        syncHomeGoalFromCloud()
    }

    // 보너스 지급 dedup 상태 동기화 — 세션 이력을 동기화하면 새 기기에서 streak·완주수가
    // 복원되므로, 슬롯/해제 보너스가 이미 지급됐다는 사실도 함께 옮겨야 중복 지급되지 않는다.
    fun mirrorSlotBonusTier(uid: String, tier: Int) {
        if (!firebaseAvailable || uid == "guest") return
        runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid)
                .set(mapOf("slotBonusAwardedTier" to tier),
                    com.google.firebase.firestore.SetOptions.merge())
        }
    }
    fun mirrorUnlockBonusAwarded(uid: String) {
        if (!firebaseAvailable || uid == "guest") return
        runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid)
                .set(mapOf("unlockBonusAwarded" to true),
                    com.google.firebase.firestore.SetOptions.merge())
        }
    }
    private suspend fun syncBonusStateFromCloud() {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        val doc = runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid).get().await()
        }.getOrNull() ?: return
        val prefs = com.singlemarks.angrymoti.data.Prefs
        // 양방향 — 큰 쪽이 이긴다. 기존 사용자(클라우드에 상태 없음)는 로컬을 올려 다음 기기가 받게 한다.
        val localTier = prefs.slotBonusAwardedTier(uid)
        val cloudTier = doc.getLong("slotBonusAwardedTier")?.toInt() ?: 0
        if (cloudTier > localTier) prefs.setSlotBonusAwardedTier(uid, cloudTier)
        else if (localTier > cloudTier) mirrorSlotBonusTier(uid, localTier)

        val localUnlock = prefs.unlockBonusAwarded(uid)
        val cloudUnlock = doc.getBoolean("unlockBonusAwarded") == true
        if (cloudUnlock && !localUnlock) prefs.setUnlockBonusAwarded(uid)
        else if (localUnlock && !cloudUnlock) mirrorUnlockBonusAwarded(uid)
    }

    /** 현재 계정의 다짐 문구를 Prefs에서 다시 읽어 flow에 반영 (계정 전환·앱 시작 시 호출) */
    fun reloadHomeGoal() {
        homeGoal.value = com.singlemarks.angrymoti.data.Prefs.homeGoal(currentUserID)
    }

    /** 홈 다짐 편집 저장 — 로컬 저장 + flow 즉시 반영 + 클라우드 업로드를 한 번에 */
    fun saveHomeGoal(text: String) {
        val uid = currentUserID
        com.singlemarks.angrymoti.data.Prefs.setHomeGoal(uid, text)
        homeGoal.value = text
        mirrorHomeGoal(text)
    }

    /** 홈 다짐(목표) 문구 업로드 — 편집 저장 시 호출 */
    fun mirrorHomeGoal(text: String) {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid)
                .set(mapOf("homeGoal" to text, "homeGoalUpdatedAt" to System.currentTimeMillis()),
                    com.google.firebase.firestore.SetOptions.merge())
        }
    }

    /** 클라우드 다짐 문구 읽기 — updatedAt이 더 최신이면 로컬을 덮어쓴다 */
    private suspend fun syncHomeGoalFromCloud() {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        val doc = runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid).get().await()
        }.getOrNull() ?: return
        val cloudText = doc.getString("homeGoal") ?: return
        val cloudUpdated = doc.getLong("homeGoalUpdatedAt") ?: 0L
        val localUpdated = com.singlemarks.angrymoti.data.Prefs.homeGoalUpdatedAt(uid)
        if (cloudUpdated > localUpdated) {
            com.singlemarks.angrymoti.data.Prefs.setHomeGoal(uid, cloudText, cloudUpdated)
            homeGoal.value = cloudText   // 화면 즉시 반영
        } else if (localUpdated > cloudUpdated) {
            mirrorHomeGoal(com.singlemarks.angrymoti.data.Prefs.homeGoal(uid))
        }
    }

    /** 개인 예약 1건 클라우드 업로드 (그룹 예약은 GroupStore가 방 문서에서 재생성하므로 제외) */
    fun mirrorReservation(r: com.singlemarks.angrymoti.data.Reservation) {
        if (!firebaseAvailable || r.ownerUserID == "guest" || r.groupId != null) return
        runCatching {
            FirebaseFirestore.getInstance().collection("users").document(r.ownerUserID)
                .collection("reservations").document(r.id.lowercase())
                .set(mapOf(
                    "name" to r.name, "tag" to r.tag,
                    "startMinute" to r.startMinute, "durationMinutes" to r.durationMinutes,
                    "repeatWeekdays" to r.repeatWeekdays,
                    "oneOffDate" to r.oneOffDayStart,
                    "createdAt" to r.createdAt,
                    "accountableFrom" to r.accountableFrom,
                    "isActive" to r.isActive,
                    "updatedAt" to (r.updatedAt ?: r.createdAt),
                ), com.google.firebase.firestore.SetOptions.merge())
        }
    }

    /** 개인 예약 양방향 병합 — updatedAt이 최신인 쪽이 이긴다 */
    private suspend fun syncReservationsFromCloud() {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        val snapshot = runCatching {
            FirebaseFirestore.getInstance()
                .collection("users").document(uid).collection("reservations").get().await()
        }.getOrNull() ?: return

        val dao = com.singlemarks.angrymoti.data.AppDb.get(appContext).reservations()
        val localByID = dao.allForOwner(uid)
            .filter { it.groupId == null }
            .associateBy { it.id.lowercase() }

        val cloudIDs = mutableSetOf<String>()
        for (doc in snapshot.documents) {
            val key = doc.id.lowercase()
            cloudIDs.add(key)
            val cloudUpdated = doc.getLong("updatedAt") ?: 0L
            @Suppress("UNCHECKED_CAST")
            val weekdays = (doc.get("repeatWeekdays") as? List<Number>)?.map { it.toInt() }
            val local = localByID[key]
            if (local != null) {
                val localUpdated = local.updatedAt ?: local.createdAt
                if (cloudUpdated > localUpdated) {
                    dao.upsert(local.copy(
                        name = doc.getString("name") ?: local.name,
                        tag = doc.getString("tag") ?: local.tag,
                        startMinute = doc.getLong("startMinute")?.toInt() ?: local.startMinute,
                        durationMinutes = doc.getLong("durationMinutes")?.toInt() ?: local.durationMinutes,
                        repeatWeekdaysCsv = weekdays?.joinToString(",") ?: local.repeatWeekdaysCsv,
                        oneOffDayStart = doc.getLong("oneOffDate"),
                        accountableFrom = doc.getLong("accountableFrom") ?: local.accountableFrom,
                        isActive = doc.getBoolean("isActive") ?: local.isActive,
                        updatedAt = cloudUpdated,
                    ))
                } else if (localUpdated > cloudUpdated) {
                    mirrorReservation(local)
                }
            } else {
                // 다른 기기(iOS 포함)에서 만든 예약 — 로컬에 생성
                val name = doc.getString("name") ?: continue
                dao.upsert(com.singlemarks.angrymoti.data.Reservation(
                    id = key, ownerUserID = uid, name = name,
                    tag = doc.getString("tag") ?: "",
                    startMinute = doc.getLong("startMinute")?.toInt() ?: 0,
                    durationMinutes = doc.getLong("durationMinutes")?.toInt() ?: 60,
                    repeatWeekdaysCsv = weekdays?.joinToString(",") ?: "",
                    oneOffDayStart = doc.getLong("oneOffDate"),
                    createdAt = doc.getLong("createdAt") ?: System.currentTimeMillis(),
                    isActive = doc.getBoolean("isActive") ?: true,
                    accountableFrom = doc.getLong("accountableFrom"),
                    updatedAt = doc.getLong("updatedAt"),
                ))
            }
        }
        // 클라우드에 아직 없는 로컬 개인 예약 → 최초 업로드 (기존 사용자 마이그레이션)
        localByID.filterKeys { it !in cloudIDs }.values.forEach(::mirrorReservation)
    }

    // MARK: 세션 요약 동기화 — 기기 변경 시 진척 보존
    // 완료 세션의 '요약'(영상 제외: 활동명·태그·강도·시각·성공여부)을 계정 클라우드에 미러한다.
    // 새 기기는 이 요약을 내려받아 연속 달성일·미친맛 해제·활동 슬롯·성공 캘린더를 이력 기준으로
    // 다시 계산한다 → 기기를 바꿔도 0으로 리셋되지 않는다. 영상 파일은 기기 로컬에만 남는다.

    /** Firestore 시간 필드를 밀리초로 — iOS(Int64)·안드로이드(Long)·구형(Timestamp) 모두 수용 */
    private fun docMillis(doc: com.google.firebase.firestore.DocumentSnapshot, key: String): Long? =
        when (val v = doc.get(key)) {
            is com.google.firebase.Timestamp -> v.toDate().time
            is Number -> v.toLong()
            else -> null
        }

    /** 완료 세션 요약 클라우드 미러 (영상 제외) — best-effort. outcome이 있어야 올린다. */
    fun mirrorSession(s: com.singlemarks.angrymoti.data.FocusSession) {
        if (!firebaseAvailable || s.ownerUserID == "guest" || s.outcomeRaw == null) return
        runCatching {
            FirebaseFirestore.getInstance().collection("users").document(s.ownerUserID)
                .collection("sessionSummaries").document(s.id.lowercase())
                .set(mapOf(
                    "activityName" to s.activityName, "tag" to s.tag,
                    "intensity" to s.intensityRaw,
                    "scheduledAt" to s.scheduledAt, "startedAt" to s.startedAt, "endedAt" to s.endedAt,
                    "targetSeconds" to s.targetSeconds, "recordedSeconds" to s.recordedSeconds,
                    "outcome" to s.outcomeRaw, "reservationID" to s.reservationID,
                    "updatedAt" to (s.endedAt ?: System.currentTimeMillis()),
                ), com.google.firebase.firestore.SetOptions.merge())
        }
    }

    /** 세션 요약 병합 — 다른 기기(iOS 포함)에서 쌓인 완료 세션을 로컬에 생성(영상 없이).
     *  로컬에 이미 있으면(영상 포함 가능) 건드리지 않는다 → 영상 참조 보존. */
    private suspend fun syncSessionSummariesFromCloud() {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        val snapshot = runCatching {
            FirebaseFirestore.getInstance()
                .collection("users").document(uid).collection("sessionSummaries").get().await()
        }.getOrNull() ?: return

        val dao = com.singlemarks.angrymoti.data.AppDb.get(appContext).sessions()
        val existing = dao.all(uid).map { it.id.lowercase() }.toSet()
        val cloudIDs = mutableSetOf<String>()
        for (doc in snapshot.documents) {
            val key = doc.id.lowercase()
            cloudIDs.add(key)
            if (key in existing) continue   // 로컬 우선 — 영상 참조 보존
            val outcome = doc.getString("outcome")?.takeIf { it.isNotEmpty() } ?: continue
            dao.upsert(com.singlemarks.angrymoti.data.FocusSession(
                id = key, ownerUserID = uid,
                activityName = doc.getString("activityName") ?: "",
                tag = doc.getString("tag") ?: "",
                intensityRaw = doc.getString("intensity") ?: "spicy",
                scheduledAt = docMillis(doc, "scheduledAt"),
                startedAt = docMillis(doc, "startedAt"),
                endedAt = docMillis(doc, "endedAt"),
                targetSeconds = (doc.getLong("targetSeconds") ?: 0L).toInt(),
                recordedSeconds = (doc.getLong("recordedSeconds") ?: 0L).toInt(),
                outcomeRaw = outcome,
                reservationID = doc.getString("reservationID")?.takeIf { it.isNotEmpty() }?.lowercase(),
            ))
        }
        // 클라우드에 아직 없는 로컬 완료 세션 → 최초 업로드 (기존 사용자 이력 마이그레이션)
        dao.all(uid).filter { it.outcomeRaw != null && it.id.lowercase() !in cloudIDs }
            .forEach(::mirrorSession)
    }

    /** 구독 상태 클라우드 기록 — 반대 플랫폼(iOS)에서도 멤버십이 인정되도록 */
    fun mirrorMembership(expiresAtMillis: Long, platform: String) {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") return
        runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid)
                .set(mapOf("proExpiresAt" to expiresAtMillis, "proPlatform" to platform),
                    com.google.firebase.firestore.SetOptions.merge())
        }
    }

    /** 클라우드 구독 상태 읽기 → SubscriptionManager에 반영 (스토어 구독 ∨ 클라우드 유효 = Pro) */
    private suspend fun syncMembershipFromCloud() {
        val uid = currentUserID
        if (!firebaseAvailable || uid == "guest") {
            SubscriptionManager.applyCloudPro(0L)
            return
        }
        val doc = runCatching {
            FirebaseFirestore.getInstance().collection("users").document(uid).get().await()
        }.getOrNull()
        SubscriptionManager.applyCloudPro(doc?.getLong("proExpiresAt") ?: 0L)
    }

    /** 클라우드 원장 내려받기 — 다른 기기(iOS 포함)에서 쌓인 점수 이벤트를 로컬 Room에 병합한다.
     *  mirror(업로드)와 짝을 이루는 다운로드 절반. 이벤트 ID 기준으로 중복 없이 합쳐진다. */
    private suspend fun syncScoreEventsFromCloud() {
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
