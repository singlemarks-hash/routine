package com.singlemarks.angrymoti.services

import android.content.Context
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.Timestamp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.data.ScoreEvent
import com.singlemarks.angrymoti.models.GroupPolicy
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreEventType
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.models.SlotPolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.tasks.await
import java.util.Calendar
import java.util.Date

/**
 * 그룹 챌린지 — iOS GroupStore와 1:1 (해체 시 참여자 예약 정리 수정본 기준).
 * 서버 구조 (Firestore, iOS와 동일 컬렉션 공유 — 크로스 플랫폼 대결 가능):
 *   groups/{roomID}: 방 설정(이름·코드·강도·시간·요일·기간·상태·인원수)
 *   groups/{roomID}/members/{uid}: 닉네임·그룹 점수·중도 포기 여부
 *   users/{uid}.groupIDs: 내가 참여한 방 ID 배열
 * 수명 주기(서버 함수 없이 클라이언트가 게으르게 처리):
 *   scheduled → (시작 시각, 2명 이상) active → (종료 시각) 결과 열람 → 30일 후 삭제
 *             → (시작 시각, 2명 미만) cancelled: 방장에게 안내 후 삭제
 */
object GroupStore {

    data class GroupRoom(
        val id: String,
        val name: String,
        val code: String,
        val hostUID: String,
        val intensityRaw: String,
        val startMinute: Int,
        val durationMinutes: Int,
        val repeatWeekdays: List<Int>,
        val startDate: Long,
        val endDate: Long,
        val status: String,          // scheduled | active | cancelled | disbanded
        val memberCount: Int,
    ) {
        val intensity get() = Intensity.from(intensityRaw)
        // startDate = 실제 시작 순간(시작일 + 시작 시각). 생성 시 그 값으로 저장한다(iOS와 통일).
        val hasStarted get() = System.currentTimeMillis() >= startDate
        /** 참여 가능 = 아직 scheduled이고 시작 11분 전이 지나지 않음 (10분 전 알람을 받을 수 있게) */
        val joinOpen get() = status == "scheduled" &&
            System.currentTimeMillis() < startDate - GroupPolicy.JOIN_CUTOFF_MINUTES * 60_000L
        val isFinished get() = System.currentTimeMillis() >= endDate
        val isHostMine get() = hostUID == AccountStore.currentUserID
        val isExpired get() = System.currentTimeMillis() >=
            endDate + GroupPolicy.RESULT_RETENTION_DAYS * 86_400_000L
    }

    data class GroupMember(
        val id: String,              // uid
        val nickname: String,
        val score: Int,
        val quit: Boolean,
        val joinedAt: Long,
    )

    class GroupException(message: String) : Exception(message)

    val rooms = MutableStateFlow<List<GroupRoom>>(emptyList())
    /** 방장 안내: 시작 시각에 2명 미만이라 자동 삭제된 방 */
    val cancelledNotices = MutableStateFlow<List<String>>(emptyList())
    /** 참여자 안내: 방장이 시작 전에 해체한 방 */
    val disbandedNotices = MutableStateFlow<List<String>>(emptyList())
    val isRefreshing = MutableStateFlow(false)

    val backendActive: Boolean get() = AccountStore.firebaseAvailable
    private val uid: String get() = AccountStore.currentUserID
    private val signedInMember: Boolean
        get() = backendActive && AccountStore.isSignedIn && uid != "guest"

    private fun db() = FirebaseFirestore.getInstance()

    // MARK: 새로고침 — 목록 + 수명 주기 처리

    suspend fun refresh(context: Context) {
        if (!signedInMember) { rooms.value = emptyList(); return }
        if (isRefreshing.value) return   // 동시 실행 방지 (안내 카드 중복 누적 차단)
        isRefreshing.value = true
        try {
            val myUid = uid
            val ids = myRoomIDs()
            val next = mutableListOf<GroupRoom>()
            for (id in ids) {
                val snapshot = runCatching { db().collection("groups").document(id).get().await() }
                    .getOrNull() ?: continue
                var room = if (snapshot.exists()) roomFrom(snapshot) else null
                if (room == null) {
                    // 방 문서가 사라짐 = 해체·취소된 방을 다른 기기가 이미 지운 경우
                    disbandedNotices.value += "참여했던 그룹방이 해체되었어요."
                    removeMembershipRef(id)
                    removeLocalReservation(context, id, purgeNoShows = true)
                    continue
                }
                if (room.status == "disbanded") {
                    if (!room.isHostMine) disbandedNotices.value += "'${room.name}' 방을 방장이 해체했어요."
                    removeMembershipRef(id)
                    // 해체는 시작 전에만 가능 — 미리 만들어 둔 예약과 혹시 찍힌 노쇼까지 정리
                    removeLocalReservation(context, id, purgeNoShows = true)
                    // 서버 정리: 내 멤버 문서를 지우고, 마지막 참여자였다면 방 문서까지 삭제
                    cleanupDisbandedRoom(id, myUid)
                    continue
                }
                // 시작 시각 도래 — 실제 멤버 수가 최소 인원 이상이면 활성화, 미만이면 취소.
                // 판정 근거는 비정규화 카운터(memberCount)가 아니라 '실제 멤버 문서 수'다 —
                // 카운터 드리프트로 멤버가 충분한 방이 잘못 취소·삭제되던 문제(#04)를 차단.
                if (room.status == "scheduled" && room.hasStarted) {
                    val roomRef = db().collection("groups").document(id)
                    val actualCount = runCatching {
                        roomRef.collection("members").get().await()
                            .count { it.getBoolean("quit") != true }
                    }.getOrDefault(room.memberCount)
                    val decided = if (actualCount >= GroupPolicy.MIN_MEMBERS_TO_START) "active" else "cancelled"
                    // compare-and-set — 아직 scheduled일 때만 바꾼다(여러 기기 동시 판정 방지) + 카운터 보정
                    val finalStatus = runCatching {
                        db().runTransaction { txn ->
                            val snap = txn.get(roomRef)
                            if (snap.getString("status") == "scheduled") {
                                txn.update(roomRef, mapOf("status" to decided, "memberCount" to actualCount))
                                decided
                            } else (snap.getString("status") ?: decided)
                        }.await()
                    }.getOrDefault(decided)
                    room = room.copy(status = finalStatus, memberCount = actualCount)
                }
                if (room.status == "cancelled") {
                    if (room.isHostMine) {
                        cancelledNotices.value += "'${room.name}' — 참여자가 부족해 그룹방이 취소되었습니다."
                    }
                    removeMembershipRef(id)
                    // mass-delete 금지 — 각자 자기 멤버 문서만 지우고, 마지막 참여자면 방 문서 삭제.
                    // (한 기기가 전원 문서를 통째로 지우던 파괴적 경로 제거 — 오판이어도 폭파 안 됨)
                    cleanupDisbandedRoom(id, myUid)
                    // 취소된 방은 예약 제거 + 그 예약에 잘못 찍힌 노쇼 기록까지 되돌린다
                    removeLocalReservation(context, id, purgeNoShows = true)
                    continue
                }
                // 30일 보존 기간 만료 → 서버에서 삭제
                if (room.isExpired) {
                    removeMembershipRef(id)
                    deleteRoomDocuments(id)
                    removeLocalReservation(context, id)
                    continue
                }
                // 그룹 예약은 참여 시점에 만들어지지만, 재설치·기기 변경 대비로 여기서도 보장한다.
                if (room.status == "scheduled" && !room.hasStarted) {
                    ensureLocalReservation(context, room)
                }
                if (room.status == "active") {
                    if (room.isFinished) {
                        removeLocalReservation(context, id)
                    } else if (isMemberActive(id, myUid)) {
                        ensureLocalReservation(context, room)
                    }
                }
                next.add(room)
            }
            rooms.value = next.sortedBy { it.startDate }
            AlarmScheduler.rescheduleAll(context)
        } finally {
            isRefreshing.value = false
        }
    }

    fun clearNotices() {
        cancelledNotices.value = emptyList()
        disbandedNotices.value = emptyList()
    }

    // MARK: 방 생성

    suspend fun createRoom(
        context: Context, name: String, nickname: String, intensity: Intensity,
        startMinute: Int, durationMinutes: Int, repeatWeekdays: List<Int>,
        startDate: Long, endDate: Long,
    ): GroupRoom {
        if (!signedInMember) throw GroupException("그룹 기능은 네트워크 연결과 로그인이 필요해요.")

        // 초대코드 — 헷갈리는 문자(0/O/1/I) 제외, 중복 시 재발급
        var code = randomCode()
        repeat(5) {
            val dup = runCatching {
                db().collection("groups").whereEqualTo("code", code).limit(1).get().await()
            }.getOrNull()
            if (dup == null || dup.isEmpty) return@repeat
            code = randomCode()
        }

        val roomRef = db().collection("groups").document()
        val data = mapOf(
            "name" to name, "code" to code, "hostUID" to uid,
            "intensity" to intensity.raw,
            "startMinute" to startMinute, "durationMinutes" to durationMinutes,
            "repeatWeekdays" to repeatWeekdays,
            "startDate" to Timestamp(Date(startDate)), "endDate" to Timestamp(Date(endDate)),
            "status" to "scheduled", "memberCount" to 1,
            "takenNicknames" to listOf(nickname.lowercase()),   // 닉네임 유일성 판정 기반(#15) — 방장 닉네임을 미리 등록
            "createdAt" to Timestamp(Date()),
        )
        try {
            roomRef.set(data).await()
            roomRef.collection("members").document(uid).set(
                mapOf("nickname" to nickname, "score" to 0, "quit" to false,
                    "joinedAt" to Timestamp(Date()),
                    "timeZoneID" to java.util.TimeZone.getDefault().id)   // 타임존 저장 (다른 나라 멤버 표시·기간 계산 기반)
            ).await()
            db().collection("users").document(uid)
                .set(mapOf("groupIDs" to FieldValue.arrayUnion(roomRef.id)),
                    com.google.firebase.firestore.SetOptions.merge()).await()
        } catch (e: Exception) {
            throw GroupException("방 생성에 실패했어요 — ${e.localizedMessage}")
        }
        val room = GroupRoom(roomRef.id, name, code, uid, intensity.raw, startMinute,
            durationMinutes, repeatWeekdays, startDate, endDate, "scheduled", 1)
        rooms.value = (rooms.value + room).sortedBy { it.startDate }
        // 예약을 지금 만들어 두어야 시작 시각 정각의 첫 알람이 울린다 (시작일 전엔 발생 없음)
        ensureLocalReservation(context, room)
        AlarmScheduler.rescheduleAll(context)
        return room
    }

    // MARK: 참여

    /** 초대코드로 방을 조회한다 (참여 전 미리보기 + 일정 충돌 검사용) */
    suspend fun lookup(code: String): GroupRoom {
        if (!signedInMember) throw GroupException("그룹 기능은 네트워크 연결과 로그인이 필요해요.")
        val normalized = code.uppercase().trim()
        val snapshot = runCatching {
            db().collection("groups").whereEqualTo("code", normalized).limit(1).get().await()
        }.getOrNull()
        val doc = snapshot?.documents?.firstOrNull()
            ?: throw GroupException("초대코드에 해당하는 방을 찾지 못했어요. 코드를 다시 확인해주세요.")
        val room = roomFrom(doc) ?: throw GroupException("방 정보를 읽지 못했어요.")
        if (room.status != "scheduled")
            throw GroupException("이미 시작됐거나 취소된 방이에요.")
        if (System.currentTimeMillis() >= room.startDate - GroupPolicy.JOIN_CUTOFF_MINUTES * 60_000L)
            throw GroupException("시작 ${GroupPolicy.JOIN_CUTOFF_MINUTES}분 전이 지나 참여가 마감된 방이에요.")
        return room
    }

    /** 그룹도 활동 슬롯 1개를 차지한다 — 슬롯이 가득 찼으면 생성·참여 모두 차단 */
    suspend fun checkSlotAvailable(context: Context) {
        val dbLocal = AppDb.get(context)
        val owner = AccountStore.currentUserID
        val reservations = dbLocal.reservations().active(owner)
        val finished = dbLocal.sessions().all(owner).filter { it.outcome != null }
            .map { Triple(it.anchorAt, it.outcome!!.isSuccess, it.outcome!!.isFailure) }
        val streak = SlotPolicy.currentStreak(finished)
        val allowed = SlotPolicy.allowedSlots(streak, SubscriptionManager.isPro.value) ?: return
        if (reservations.size >= allowed) {
            throw GroupException("활동 슬롯이 가득 찼어요 (${reservations.size}/$allowed). " +
                "그룹도 슬롯 1개를 차지해요 — 기존 활동을 정리하거나 연속 달성으로 슬롯을 늘려주세요.")
        }
    }

    /** 내 예약과 방 일정이 겹치는지 검사 — 겹치면 예약 이름을 담아 던진다 */
    suspend fun checkScheduleConflict(
        context: Context, startMinute: Int, durationMinutes: Int,
        repeatWeekdays: List<Int>, startDate: Long, endDate: Long,
    ) {
        val mine = AppDb.get(context).reservations().active(AccountStore.currentUserID)
        val cal = Calendar.getInstance()
        for (r in mine) {
            if (!r.overlaps(startMinute, durationMinutes)) continue
            if (r.isRepeating) {
                if (r.repeatWeekdays.any { it in repeatWeekdays }) {
                    throw GroupException("기존 예약 '${r.name}'과(와) 시간이 겹쳐요. " +
                        "개인 예약을 옮기거나 삭제해야 참여할 수 있어요.")
                }
            } else {
                val day = r.oneOffDayStart ?: continue
                cal.timeInMillis = day
                val weekday = cal.get(Calendar.DAY_OF_WEEK)
                val startDay = Calendar.getInstance().apply {
                    timeInMillis = startDate
                    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                    set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                }.timeInMillis
                if (day >= startDay && day <= endDate && weekday in repeatWeekdays) {
                    throw GroupException("기존 예약 '${r.name}'과(와) 시간이 겹쳐요. " +
                        "개인 예약을 옮기거나 삭제해야 참여할 수 있어요.")
                }
            }
        }
    }

    suspend fun checkScheduleConflict(context: Context, room: GroupRoom) =
        checkScheduleConflict(context, room.startMinute, room.durationMinutes,
            room.repeatWeekdays, room.startDate, room.endDate)

    /** 방에 참여한다 (닉네임 선점·정원·중복 참여 검사 포함) */
    suspend fun join(context: Context, room: GroupRoom, nickname: String) {
        if (!signedInMember) throw GroupException("그룹 기능은 네트워크 연결과 로그인이 필요해요.")
        val roomRef = db().collection("groups").document(room.id)
        val memberRef = roomRef.collection("members").document(uid)
        val lowerNick = nickname.lowercase()

        // 정원 초과·닉네임 중복·중복 참여·마감을 '하나의 트랜잭션'으로 원자 확정(#15).
        // 읽고-쓰기가 분리돼 있으면 동시 참여 2건이 같은 빈자리·같은 닉네임을 함께 통과해
        // 정원 +1 초과나 동명이인이 생긴다 — 트랜잭션이 방 문서(memberCount·takenNicknames)를
        // 원자적으로 검사·갱신해 이 경합을 막는다. (Firestore 트랜잭션은 컬렉션 질의가 불가하므로
        //  닉네임 유일성은 방 문서의 takenNicknames 배열로 판정한다.)
        try {
            db().runTransaction { txn ->
                val snap = txn.get(roomRef)
                val mine = txn.get(memberRef)   // 읽기는 모두 쓰기보다 앞
                if (!snap.exists()) throw GroupException("초대코드에 해당하는 방을 찾지 못했어요.")
                if (snap.getString("status") != "scheduled")
                    throw GroupException("이미 시작됐거나 취소된 방이에요.")
                val startDate = snap.getTimestamp("startDate")?.toDate()?.time ?: 0L
                if (System.currentTimeMillis() >= startDate - GroupPolicy.JOIN_CUTOFF_MINUTES * 60_000L)
                    throw GroupException("시작 ${GroupPolicy.JOIN_CUTOFF_MINUTES}분 전이 지나 참여가 마감됐어요. (10분 전 알람을 받을 수 있어야 참여할 수 있어요)")
                if (mine.exists()) throw GroupException("이미 참여 중인 방이에요.")
                val count = (snap.getLong("memberCount") ?: 0L).toInt()
                if (count >= GroupPolicy.MAX_MEMBERS)
                    throw GroupException("이 방은 정원(${GroupPolicy.MAX_MEMBERS}명)이 가득 찼어요.")
                @Suppress("UNCHECKED_CAST")
                val taken = (snap.get("takenNicknames") as? List<String>) ?: emptyList()
                if (taken.any { it.equals(lowerNick, ignoreCase = true) })
                    throw GroupException("이미 사용 중인 닉네임이에요. 다른 닉네임을 입력해주세요.")
                txn.set(memberRef, mapOf("nickname" to nickname, "score" to 0, "quit" to false,
                    "joinedAt" to Timestamp(Date()),
                    "timeZoneID" to java.util.TimeZone.getDefault().id))   // 타임존 저장 (다른 나라 멤버 표시·기간 계산 기반)
                txn.update(roomRef, mapOf(
                    "memberCount" to count + 1,
                    "takenNicknames" to FieldValue.arrayUnion(lowerNick)))
            }.await()
        } catch (e: Exception) {
            // 트랜잭션 함수가 던진 GroupException(친절한 사유)을 그대로 전달
            throw (e as? GroupException) ?: (e.cause as? GroupException)
                ?: GroupException("참여에 실패했어요 — ${e.localizedMessage}")
        }
        // 내 계정 문서의 그룹 목록 — 경합 무관(merge)이라 트랜잭션 밖
        runCatching {
            db().collection("users").document(uid)
                .set(mapOf("groupIDs" to FieldValue.arrayUnion(room.id)),
                    com.google.firebase.firestore.SetOptions.merge()).await()
        }
        // 예약을 지금 만들어 두어야 시작 시각 정각의 첫 알람이 울린다 (시작일 전엔 발생 없음)
        ensureLocalReservation(context, room)
        AlarmScheduler.rescheduleAll(context)
        refresh(context)
    }

    // MARK: 멤버 & 랭킹

    suspend fun members(roomID: String): List<GroupMember> {
        if (!backendActive) return emptyList()
        val snapshot = runCatching {
            db().collection("groups").document(roomID).collection("members").get().await()
        }.getOrNull() ?: return emptyList()
        return snapshot.documents.mapNotNull { doc ->
            val nickname = doc.getString("nickname") ?: return@mapNotNull null
            GroupMember(
                id = doc.id, nickname = nickname,
                score = (doc.getLong("score") ?: 0L).toInt(),
                quit = doc.getBoolean("quit") ?: false,
                joinedAt = doc.getTimestamp("joinedAt")?.toDate()?.time
                    ?: System.currentTimeMillis(),
            )
        }
    }

    /** 점수 내림차순 + 공동 등수(1224 방식). 동점이면 같은 등수, 다음 등수는 인원만큼 건너뛴다. */
    fun ranked(members: List<GroupMember>): List<Pair<Int, GroupMember>> {
        val sorted = members.sortedWith(
            compareByDescending<GroupMember> { it.score }.thenBy { it.joinedAt })
        val result = mutableListOf<Pair<Int, GroupMember>>()
        var rank = 0
        var previousScore = Int.MIN_VALUE
        sorted.forEachIndexed { index, member ->
            if (member.score != previousScore) {
                rank = index + 1
                previousScore = member.score
            }
            result.add(rank to member)
        }
        return result
    }

    // MARK: 그룹 점수 반영 (세션 판정 시 호출)

    /** 그룹 예약에서 나온 상벌점을 서버의 내 멤버 점수에 합산한다. 실패해도 로컬 원장이 원본. */
    fun reportScore(reservation: Reservation?, points: Int) {
        val roomID = reservation?.groupId ?: return
        if (!backendActive || points == 0) return
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return
        runCatching {
            db().collection("groups").document(roomID)
                .collection("members").document(myUid)
                .update("score", FieldValue.increment(points.toLong()))
        }
    }

    // MARK: 탈퇴 · 해체 · 나가기

    /** 시작 전 자유 탈퇴 — 멤버 삭제 + 인원수 감소 */
    suspend fun leaveBeforeStart(context: Context, room: GroupRoom) {
        if (!signedInMember) return
        val roomRef = db().collection("groups").document(room.id)
        val memberRef = roomRef.collection("members").document(uid)
        // 내 닉네임을 takenNicknames에서 풀어 재사용 가능하게(#15) — 삭제 전에 읽어 둔다
        val myNick = runCatching { memberRef.get().await().getString("nickname") }.getOrNull()
        runCatching { memberRef.delete().await() }
        val updates = mutableMapOf<String, Any>("memberCount" to FieldValue.increment(-1))
        myNick?.let { updates["takenNicknames"] = FieldValue.arrayRemove(it.lowercase()) }
        runCatching { roomRef.update(updates).await() }
        removeMembershipRef(room.id)
        removeLocalReservation(context, room.id)   // 미리 만들어 둔 예약 정리
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    /** 시작 후 중도 포기 — 벌점 -50 (그룹 점수 + 개인 누적), 남은 그룹 일정 삭제 */
    suspend fun quitAfterStart(context: Context, room: GroupRoom) {
        if (!signedInMember) return
        val memberRef = db().collection("groups").document(room.id)
            .collection("members").document(uid)
        runCatching {
            memberRef.update(mapOf(
                "quit" to true,
                "score" to FieldValue.increment(ScoreRules.GROUP_QUIT_PENALTY.toLong()),
            )).await()
        }
        // 개인 누적에도 동일 벌점 기록
        val event = ScoreEvent(
            ownerUserID = uid, typeRaw = ScoreEventType.GROUP_QUIT.raw,
            points = ScoreRules.GROUP_QUIT_PENALTY, sessionID = null,
            intensityRaw = room.intensityRaw, note = "그룹 '${room.name}' 중도 포기")
        AppDb.get(context).scores().insert(event)
        AccountStore.mirror(event)
        removeLocalReservation(context, room.id)
        removeMembershipRef(room.id)
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    /** 방장 전용, 시작 전 해체 — 참여자들은 다음 새로고침에서 안내를 받는다 */
    suspend fun disband(context: Context, room: GroupRoom) {
        if (!signedInMember || !room.isHostMine) return
        runCatching {
            db().collection("groups").document(room.id).update("status", "disbanded").await()
        }
        removeMembershipRef(room.id)
        // 방장 자신의 멤버 문서 정리 — 혼자였던 방이면 문서까지 즉시 삭제,
        // 참여자가 있으면 status로 해체를 알린 뒤 마지막 참여자가 문서를 지운다
        cleanupDisbandedRoom(room.id, uid)
        removeLocalReservation(context, room.id)   // 미리 만들어 둔 예약 정리
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    /** 종료된 방 '나가기' — 내 목록에서만 사라진다 (다른 참여자의 결과는 유지) */
    suspend fun hideFinishedRoom(room: GroupRoom) {
        removeMembershipRef(room.id)
        rooms.value = rooms.value.filterNot { it.id == room.id }
    }

    // MARK: 내부

    /** 활성 방의 그룹 예약이 내 기기에 없으면 만든다.
     *  createdAt을 방 시작일로 두어, 앱을 늦게 열어도 시작일 이후의 노쇼가 전부 집계된다. */
    private suspend fun ensureLocalReservation(context: Context, room: GroupRoom) {
        val dao = AppDb.get(context).reservations()
        val owner = AccountStore.currentUserID
        if (dao.byGroup(owner, room.id).any { it.isActive }) return
        // 일회성 그룹(요일 없음)은 방 시작일 하루만 발생 → oneOffDayStart 지정
        val oneOff = if (room.repeatWeekdays.isEmpty()) {
            java.util.Calendar.getInstance().apply {
                timeInMillis = room.startDate
                set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
        } else null
        dao.upsert(Reservation(
            ownerUserID = owner, name = room.name, tag = "그룹",
            startMinute = room.startMinute, durationMinutes = room.durationMinutes,
            repeatWeekdaysCsv = room.repeatWeekdays.joinToString(","),
            oneOffDayStart = oneOff,
            createdAt = room.startDate,
            groupId = room.id, endAt = room.endDate,
            intensityOverrideRaw = room.intensityRaw,
        ))
    }

    /** purgeNoShows: 방이 무산(취소·해체)됐을 때 — 그 예약에 찍힌 노쇼 세션·벌점을 함께 되돌린다 */
    private suspend fun removeLocalReservation(
        context: Context, roomID: String, purgeNoShows: Boolean = false,
    ) {
        val dbLocal = AppDb.get(context)
        val owner = AccountStore.currentUserID
        val list = dbLocal.reservations().byGroup(owner, roomID)
        for (reservation in list) {
            if (purgeNoShows) {
                val sessions = dbLocal.sessions().all(owner).filter {
                    it.reservationID == reservation.id &&
                        it.outcome == SessionOutcome.NO_SHOW
                }
                for (session in sessions) {
                    for (e in dbLocal.scores().bySession(session.id)) dbLocal.scores().delete(e)
                    dbLocal.sessions().delete(session)
                }
            }
            // 폭파·취소·해체된 그룹 예약은 DB에서 완전 삭제 (소프트 삭제 아님) —
            // 방 문서가 사라졌으니 재생성되지 않는다.
            dbLocal.reservations().delete(reservation)
        }
    }

    private suspend fun myRoomIDs(): List<String> {
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return emptyList()
        val doc = runCatching {
            db().collection("users").document(myUid).get().await()
        }.getOrNull() ?: return emptyList()
        @Suppress("UNCHECKED_CAST")
        return doc.get("groupIDs") as? List<String> ?: emptyList()
    }

    private suspend fun removeMembershipRef(roomID: String) {
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return
        runCatching {
            db().collection("users").document(myUid)
                .set(mapOf("groupIDs" to FieldValue.arrayRemove(roomID)),
                    com.google.firebase.firestore.SetOptions.merge()).await()
        }
    }

    /** 해체된 방의 서버 흔적 정리 — 내 멤버 문서 삭제, 남은 멤버가 없으면 방 문서까지 삭제 */
    private suspend fun cleanupDisbandedRoom(roomID: String, myUid: String) {
        val roomRef = db().collection("groups").document(roomID)
        runCatching { roomRef.collection("members").document(myUid).delete().await() }
        val remaining = runCatching {
            roomRef.collection("members").limit(1).get().await()
        }.getOrNull()
        if (remaining != null && remaining.isEmpty) {
            runCatching { roomRef.delete().await() }
        }
    }

    /** 방 문서 + 멤버 하위 컬렉션 삭제 (하위 컬렉션은 자동 삭제되지 않는다) */
    private suspend fun deleteRoomDocuments(roomID: String) {
        val roomRef = db().collection("groups").document(roomID)
        runCatching {
            val members = roomRef.collection("members").get().await()
            for (doc in members.documents) runCatching { doc.reference.delete().await() }
        }
        runCatching { roomRef.delete().await() }
    }

    private fun roomFrom(doc: DocumentSnapshot): GroupRoom? {
        val name = doc.getString("name") ?: return null
        val code = doc.getString("code") ?: return null
        val hostUID = doc.getString("hostUID") ?: return null
        val startMinute = doc.getLong("startMinute")?.toInt() ?: return null
        val durationMinutes = doc.getLong("durationMinutes")?.toInt() ?: return null
        val startTS = doc.getTimestamp("startDate") ?: return null
        val endTS = doc.getTimestamp("endDate") ?: return null
        @Suppress("UNCHECKED_CAST")
        val weekdays = (doc.get("repeatWeekdays") as? List<Number>)?.map { it.toInt() } ?: emptyList()
        return GroupRoom(
            id = doc.id, name = name, code = code, hostUID = hostUID,
            intensityRaw = doc.getString("intensity") ?: Intensity.SPICY.raw,
            startMinute = startMinute, durationMinutes = durationMinutes,
            repeatWeekdays = weekdays,
            startDate = startTS.toDate().time, endDate = endTS.toDate().time,
            status = doc.getString("status") ?: "scheduled",
            memberCount = (doc.getLong("memberCount") ?: 0L).toInt(),
        )
    }

    /** 내가 아직 유효한(중도 포기 아님) 멤버인가 */
    private suspend fun isMemberActive(roomID: String, myUid: String): Boolean {
        val doc = runCatching {
            db().collection("groups").document(roomID)
                .collection("members").document(myUid).get().await()
        }.getOrNull() ?: return false
        if (!doc.exists()) return false
        return (doc.getBoolean("quit") ?: false) == false
    }

    private fun randomCode(): String {
        val charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   // 0/O/1/I 제외
        return (1..GroupPolicy.CODE_LENGTH).map { charset.random() }.joinToString("")
    }
}
