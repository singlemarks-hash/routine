package com.singlemarks.angrymoti.services

import android.content.Context
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.Timestamp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.data.ScoreEvent
import com.singlemarks.angrymoti.models.CanonicalTag
import com.singlemarks.angrymoti.models.ScoreNote
import com.singlemarks.angrymoti.models.GroupPolicy
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreEventType
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.models.SlotPolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
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
        /** 참여 마감 후 인원 미달로 시작 시각에 삭제될 방 — 알람 취소·점수화 차단 대상 */
        val doomed: Boolean = false,
    ) {
        val intensity get() = Intensity.from(intensityRaw)
        // startDate = 실제 시작 순간(시작일 + 시작 시각). 생성 시 그 값으로 저장한다(iOS와 통일).
        val hasStarted get() = System.currentTimeMillis() >= startDate
        /** 참여 가능 = 아직 scheduled이고 시작 11분 전이 지나지 않음 (10분 전 알람을 받을 수 있게) */
        val joinOpen get() = status == "scheduled" &&
            System.currentTimeMillis() < startDate - GroupPolicy.JOIN_CUTOFF_MINUTES * 60_000L

        /**
         * 방의 실제 종료 시각 = 마지막 발생일의 시작 시각 + 활동 길이 + 정산 유예(25분).
         * endDate(종료일 23:59:59)로 판정하면 오전에 끝난 하루짜리 방이 하루 종일
         * '진행 중'으로 남는다 (iOS finishedAt과 동일 로직).
         */
        val finishedAt: Long get() {
            fun startOfDay(t: Long): Long = Calendar.getInstance().apply {
                timeInMillis = t
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }.timeInMillis
            val firstDay = startOfDay(startDate)
            val lastDay = startOfDay(endDate)
            val days = repeatWeekdays.toSet()
            // 마지막 발생일: 종료일부터 거꾸로 8일 안에서 고른 요일이 오는 첫 날.
            // 못 찾으면 종료일(늦게 끝나는 쪽이 안전). 요일 없는 레거시 = 시작일 하루.
            var occurrenceDay = if (days.isEmpty()) firstDay else lastDay
            if (days.isNotEmpty()) {
                for (offset in 0 until 8) {
                    val day = lastDay - offset * 86_400_000L
                    if (day < firstDay) break
                    val wd = Calendar.getInstance().apply { timeInMillis = day }
                        .get(Calendar.DAY_OF_WEEK)
                    if (wd in days) { occurrenceDay = day; break }
                }
            }
            val base = occurrenceDay + startMinute * 60_000L
            return base + (durationMinutes + GroupPolicy.SETTLE_GRACE_MINUTES) * 60_000L
        }

        val isFinished get() = System.currentTimeMillis() >= finishedAt
        val deleteAt get() = finishedAt + GroupPolicy.RESULT_RETENTION_DAYS * 86_400_000L
        val isHostMine get() = hostUID == AccountStore.currentUserID
        val isExpired get() = System.currentTimeMillis() >= deleteAt
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
        // 동시 실행 방지 (안내 카드 중복 누적·수명주기 이중 처리 차단) — 검사-후-설정을
        // 원자로 해야 한다. 앱 복귀와 그룹 탭 진입이 겹치면 둘 다 검사를 통과해 refresh가
        // 두 벌 돌던 경합을 CAS로 막는다.
        if (!isRefreshing.compareAndSet(expect = false, update = true)) return
        try {
            val myUid = uid
            // 조회 실패(null)면 이번 새로고침은 통째로 건너뛴다 — 빈 목록으로 오해해
            // 정상 그룹 예약을 지우거나 방 목록을 날리면 안 된다.
            val ids = myRoomIDs() ?: return
            val next = mutableListOf<GroupRoom>()
            for (id in ids) {
                val snapshot = runCatching { db().collection("groups").document(id).get().await() }
                    .getOrNull()
                if (snapshot == null) {
                    // 조회 실패는 '방이 없다'가 아니다 — 아무것도 지우지 않고 이전 상태를 유지한다.
                    // (여기서 next에 안 넣으면 진행 중인 방이 목록에서 통째로 사라져 보인다)
                    rooms.value.firstOrNull { it.id == id }?.let { next.add(it) }
                    continue
                }
                var room = if (snapshot.exists()) roomFrom(snapshot) else null
                if (room == null && snapshot.exists()) {
                    // 파싱 실패(필수 필드 누락) — 삭제로 오해하지 말고 이전 객체 유지
                    rooms.value.firstOrNull { it.id == id }?.let { next.add(it) }
                    continue
                }
                if (room == null) {
                    // 방 문서가 사라짐 — 이유는 알 수 없다. '진행을 목격한 방'이면 보존 만료
                    // 정리이므로 정당한 벌점을 유지하고, 목격한 적 없으면 시작 전에 정리된
                    // 방이므로 미리 찍힌 벌점까지 되돌린다.
                    val everRan = id in Prefs.seenActiveRoomIDs
                    if (!removeMembershipRef(id)) continue   // 참조 정리 실패 — 다음 새로고침에 재시도
                    disbandedNotices.value += if (everRan)
                        com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.group_cleanup_retention)
                    else
                        com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.group_cleanup_never_started)
                    removeLocalReservation(context, id, purgeNoShows = !everRan)
                    forgetRoomActive(id)
                    continue
                }
                if (room.status == "disbanded") {
                    if (!removeMembershipRef(id)) { next.add(room); continue }
                    if (!room.isHostMine) disbandedNotices.value += com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.host_disbanded_room, room.name)
                    // 해체는 시작 전에만 가능 — 미리 만들어 둔 예약과 혹시 찍힌 노쇼까지 정리
                    removeLocalReservation(context, id, purgeNoShows = true)
                    forgetRoomActive(id)
                    // 서버 정리: 내 멤버 문서를 지우고, 마지막 참여자였다면 방 문서까지 삭제
                    cleanupDisbandedRoom(id, myUid)
                    continue
                }
                // doomed 승계 — 조회 실패 회차에 판정이 풀려 예약·알람이 되살아나지 않게
                if (rooms.value.firstOrNull { it.id == id }?.doomed == true) {
                    room = room.copy(doomed = true)
                }
                // 참여 마감 후 인원 미달 = 시작 시각에 삭제될 방(doomed).
                // 서버 소스 강제 — 오프라인 캐시가 '나 혼자'로 답해 멀쩡한 방을
                // 삭제 예정으로 오판하면 예약·알람이 부당하게 죽는다.
                if (room.status == "scheduled" && !room.hasStarted && !room.joinOpen) {
                    val memberSnap = runCatching {
                        db().collection("groups").document(id).collection("members")
                            .get(com.google.firebase.firestore.Source.SERVER).await()
                    }.getOrNull()
                    if (memberSnap != null) {
                        val liveCount = memberSnap.count { it.getBoolean("quit") != true }
                        room = room.copy(memberCount = liveCount,
                            doomed = liveCount < GroupPolicy.MIN_MEMBERS_TO_START)
                    }
                    if (room.doomed) {
                        // 진행되지 않을 방 — 알람을 끄고, 미리 찍힌 기록도 점수화 전에 되돌린다
                        removeLocalReservation(context, id, purgeNoShows = true)
                        next.add(room)
                        continue
                    }
                }
                // 시작 시각 도래 — 실제 멤버 수가 최소 인원 이상이면 활성화, 미만이면 취소.
                // 판정 근거는 비정규화 카운터(memberCount)가 아니라 '실제 멤버 문서 수'다 —
                // 카운터 드리프트로 멤버가 충분한 방이 잘못 취소·삭제되던 문제(#04)를 차단.
                if (room.status == "scheduled" && room.hasStarted) {
                    val roomRef = db().collection("groups").document(id)
                    // 멤버 문서를 못 읽었으면 판정 자체를 미룬다. 캐시된 카운터로 '취소'를
                    // 내리면 정상 진행 중인 방이 폭파된다 — 네트워크 복구 후 재판정하면 된다.
                    val actualCount = runCatching {
                        roomRef.collection("members").get().await()
                            .count { it.getBoolean("quit") != true }
                    }.getOrNull()
                    if (actualCount == null) { next.add(room); continue }
                    val decided = if (actualCount >= GroupPolicy.MIN_MEMBERS_TO_START) "active" else "cancelled"
                    // compare-and-set — 아직 scheduled일 때만 바꾼다(여러 기기 동시 판정 방지) + 카운터 보정.
                    // 커밋 실패면 판정을 적용하지 않는다 — 서버는 scheduled인데 로컬만 cancelled로
                    // 굴러가면 멀쩡한 방의 예약을 지우게 된다.
                    val finalStatus = runCatching {
                        db().runTransaction { txn ->
                            val snap = txn.get(roomRef)
                            if (snap.getString("status") == "scheduled") {
                                txn.update(roomRef, mapOf("status" to decided, "memberCount" to actualCount))
                                decided
                            } else (snap.getString("status") ?: decided)
                        }.await()
                    }.getOrNull()
                    if (finalStatus == null) { next.add(room); continue }
                    room = room.copy(status = finalStatus, memberCount = actualCount)
                }
                if (room.status == "cancelled") {
                    if (!removeMembershipRef(id)) { next.add(room); continue }
                    if (room.isHostMine) {
                        cancelledNotices.value += com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_cancelled_too_few, room.name)
                    }
                    // mass-delete 금지 — 각자 자기 멤버 문서만 지우고, 마지막 참여자면 방 문서 삭제.
                    cleanupDisbandedRoom(id, myUid)
                    // 취소된 방은 예약 제거 + 그 예약에 잘못 찍힌 노쇼 기록까지 되돌린다
                    removeLocalReservation(context, id, purgeNoShows = true)
                    forgetRoomActive(id)
                    continue
                }
                // 보존 기간 만료 → 서버에서 삭제 (finishedAt + 30일)
                if (room.isExpired) {
                    if (!removeMembershipRef(id)) { next.add(room); continue }
                    deleteRoomDocuments(id)
                    removeLocalReservation(context, id)
                    forgetRoomActive(id)
                    continue
                }
                // 그룹 예약은 참여 시점에 만들어지지만, 재설치·기기 변경 대비로 여기서도 보장한다.
                if (room.status == "scheduled" && !room.hasStarted) {
                    ensureLocalReservation(context, room)
                }
                if (room.status == "active") {
                    markRoomActive(id)
                    // 끝난 방의 예약은 여기서 지우지 않는다 — 마지막 날 노쇼 집계 근거가
                    // 사라진다. 은퇴는 cleanupExpiredReservations(다음날 0시)가 맡는다.
                    if (!room.isFinished && isMemberActive(id, myUid)) {
                        ensureLocalReservation(context, room)
                    }
                }
                next.add(room)
            }
            // 고아 예약 정리 기준은 ids(멤버십 목록)다 — next가 아니다.
            // next를 쓰면 방 문서 조회 1회 실패만으로 진행 중인 그룹 예약이 삭제되고,
            // 다음 새로고침에 새로 만들어져 완료한 날까지 전부 노쇼로 재집계된다.
            pruneOrphanGroupReservations(context, ids.toSet())
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
        if (!signedInMember) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.group_needs_network_login))

        // 초대코드 — 헷갈리는 문자(0/O/1/I) 제외, 중복 시 재발급.
        // 고유가 확인되면 즉시 멈춘다 — 계속 돌면 확인된 코드를 최대 4번 더 재검사하는 낭비.
        var code = randomCode()
        run {
            repeat(5) {
                val dup = runCatching {
                    db().collection("groups").whereEqualTo("code", code).limit(1).get().await()
                }.getOrNull()
                if (dup == null || dup.isEmpty) return@run
                code = randomCode()
            }
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
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.create_room_failed, e.localizedMessage ?: ""))
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
        if (!signedInMember) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.group_needs_network_login))
        val normalized = code.uppercase().trim()
        val snapshot = runCatching {
            db().collection("groups").whereEqualTo("code", normalized).limit(1).get().await()
        }.getOrNull()
        val doc = snapshot?.documents?.firstOrNull()
            ?: throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_not_found_check))
        val room = roomFrom(doc) ?: throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_read_failed))
        if (room.status != "scheduled")
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_started_or_cancelled))
        if (System.currentTimeMillis() >= room.startDate - GroupPolicy.JOIN_CUTOFF_MINUTES * 60_000L)
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.join_closed, GroupPolicy.JOIN_CUTOFF_MINUTES))
        return room
    }

    /** 그룹도 활동 슬롯 1개를 차지한다 — 슬롯이 가득 찼으면 생성·참여 모두 차단 */
    suspend fun checkSlotAvailable(context: Context) {
        val dbLocal = AppDb.get(context)
        val owner = AccountStore.currentUserID
        // 끝난 활동은 슬롯을 차지하지 않는다 — 오늘 일정에 남아 있어도 자리는 이미 돌려줬다
        val reservations = dbLocal.reservations().active(owner).filter { it.hasRemainingOccurrence() }
        val streak = SlotPolicy.currentStreak(dbLocal.sessions().all(owner))
        val allowed = SlotPolicy.allowedSlots(streak, SubscriptionManager.isPro.value) ?: return
        if (reservations.size >= allowed) {
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.slots_full_group, reservations.size, allowed))
        }
    }

    /** 내 예약과 방 일정이 겹치는지 검사 — 겹치면 예약 이름을 담아 던진다.
     *  개인 예약 편집과 완전히 같은 규칙(ScheduleConflict)을 쓴다 — 예전 '요일·시각만 비교'
     *  로직은 이미 끝난 개인 활동이 새 방 생성을 영영 막았고, 자정을 넘기는 활동은
     *  다음날 새벽 방과 안 겹친다고 오판했다. */
    suspend fun checkScheduleConflict(
        context: Context, startMinute: Int, durationMinutes: Int,
        repeatWeekdays: List<Int>, startDate: Long, endDate: Long,
    ) {
        val mine = AppDb.get(context).reservations().active(AccountStore.currentUserID)
        fun dayStart(t: Long): Long = Calendar.getInstance().apply {
            timeInMillis = t
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val roomLo = dayStart(startDate)
        val roomHi = dayStart(endDate)
        for (r in mine) {
            val (bLo, bHi) = r.activeDayRange()
            if (com.singlemarks.angrymoti.models.ScheduleConflict.conflicts(
                    roomLo, roomHi, repeatWeekdays.toSet(), startMinute, durationMinutes,
                    bLo, bHi, r.occupiedWeekdays(), r.startMinute, r.durationMinutes)) {
                throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.schedule_overlap_join, r.name))
            }
        }
    }

    suspend fun checkScheduleConflict(context: Context, room: GroupRoom) =
        checkScheduleConflict(context, room.startMinute, room.durationMinutes,
            room.repeatWeekdays, room.startDate, room.endDate)

    /** 방에 참여한다 (닉네임 선점·정원·중복 참여 검사 포함) */
    suspend fun join(context: Context, room: GroupRoom, nickname: String) {
        if (!signedInMember) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.group_needs_network_login))
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
                if (!snap.exists()) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_not_found))
                if (snap.getString("status") != "scheduled")
                    throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_started_or_cancelled))
                val startDate = snap.getTimestamp("startDate")?.toDate()?.time ?: 0L
                if (System.currentTimeMillis() >= startDate - GroupPolicy.JOIN_CUTOFF_MINUTES * 60_000L)
                    throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.join_closed_alert_note, GroupPolicy.JOIN_CUTOFF_MINUTES))
                if (mine.exists()) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.already_in_room))
                val count = (snap.getLong("memberCount") ?: 0L).toInt()
                if (count >= GroupPolicy.MAX_MEMBERS)
                    throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_full, GroupPolicy.MAX_MEMBERS))
                @Suppress("UNCHECKED_CAST")
                val taken = (snap.get("takenNicknames") as? List<String>) ?: emptyList()
                if (taken.any { it.equals(lowerNick, ignoreCase = true) })
                    throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.nickname_taken))
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
                ?: GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.join_failed_reason, e.localizedMessage ?: ""))
        }
        // 내 계정 문서의 그룹 목록 — 경합 무관(merge)이라 트랜잭션 밖.
        // 여기서 실패를 삼키면 안 된다: 서버엔 멤버로 등록됐는데 내 그룹 목록에는 없어서,
        // 곧바로 도는 고아 정리가 방금 만든 예약을 지워 버린다(알람 없이 노쇼만 쌓임).
        try {
            db().collection("users").document(uid)
                .set(mapOf("groupIDs" to FieldValue.arrayUnion(room.id)),
                    com.google.firebase.firestore.SetOptions.merge()).await()
        } catch (_: Exception) {
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.joined_save_failed))
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
        val list = snapshot.documents.mapNotNull { doc ->
            val nickname = doc.getString("nickname") ?: return@mapNotNull null
            GroupMember(
                id = doc.id, nickname = nickname,
                score = (doc.getLong("score") ?: 0L).toInt(),
                quit = doc.getBoolean("quit") ?: false,
                joinedAt = doc.getTimestamp("joinedAt")?.toDate()?.time
                    ?: System.currentTimeMillis(),
            )
        }
        // 랭킹을 그리기 전에 내 점수가 표식 합계와 맞는지 확인한다. 방금 읽은 값을 그대로
        // 대조에 쓴다(왕복 추가 없음). 캐시 응답이면 오래된 값으로 멀쩡한 점수를 망치므로
        // 서버에서 온 응답일 때만 본다. 고쳤으면 이번 화면에 바로 반영한다.
        if (!snapshot.metadata.isFromCache) {
            val mineIdx = list.indexOfFirst { it.id == uid }
            if (mineIdx >= 0) {
                repairMyScore(roomID, list[mineIdx].score)?.let { fixed ->
                    return list.toMutableList().apply {
                        this[mineIdx] = this[mineIdx].copy(score = fixed)
                    }
                }
            }
        }
        return list
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

    // MARK: 그룹 점수 반영 (세션 판정 시 호출) — iOS와 동일한 멱등 원장(도장) 방식

    /** 노쇼는 '아직 결과를 못 본' 추정치라 가장 낮은 등급이다. */
    const val SCORE_RANK_NO_SHOW = 0
    /** 실제로 화면을 통과한 결과(완주·이탈실패·긴급종료·일정취소)는 노쇼를 덮는다. */
    const val SCORE_RANK_NORMAL = 1

    /** 중도 포기 벌점의 표식 키 — 방마다 한 번뿐이라 방 ID로 고정한다. */
    fun quitOccurrenceKey(roomID: String) = "groupquit|$roomID"

    /** MD5 → UUID 형식 소문자 (iOS deterministicUUID와 바이트 단위 동일) */
    private fun md5Uuid(key: String): String {
        val hex = java.security.MessageDigest.getInstance("MD5")
            .digest(key.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}" +
            "-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }

    /** 발생 키를 문서 ID로 — iOS와 바이트 단위 동일해야 두 플랫폼이 같은 도장을 찍는다. */
    private fun markId(occurrenceKey: String): String = md5Uuid("groupscore|$occurrenceKey")

    /** 그룹 예약 결정적 ID — iOS stableReservationID와 동일 해시.
     *  그룹 예약은 클라우드에 미러되지 않아 기기마다 새로 만들어지는데, ID가 무작위면
     *  ① 클라우드 세션 기록이 예약에 연결되지 않아 재설치·기기 추가 시 완주한 날까지
     *  소급 노쇼로 재집계되고 ② 발생 키(예약ID 기반)가 플랫폼마다 갈려 점수 도장이
     *  이중으로 찍힌다 — 멱등 원장이 크로스 플랫폼에서 무효가 된다. */
    fun stableReservationId(roomID: String, owner: String): String =
        md5Uuid("groupres|${roomID.lowercase()}|${owner.lowercase()}")

    private val scoreScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

    /** 세션 판정 경로용 래퍼 — 실패해도 로컬 원장이 원본이므로 던지지 않는다. */
    fun reportScore(reservation: Reservation?, points: Int, occurrenceKey: String, rank: Int) {
        val roomID = reservation?.groupId ?: return
        scoreScope.launch {
            runCatching { applyScore(roomID, points, occurrenceKey, rank) }
        }
    }

    /**
     * 그룹 점수를 바꾸는 **유일한** 경로. 점수 변화는 반드시 표식(도장)을 남기고 일어난다.
     *
     * 그룹 점수는 더하기 방식이라 기기가 둘이면 같은 발생을 각자 집계해 두 번 들어간다.
     * 그래서 발생마다 members/{uid}/scored/{markID}에 '반영함' 표식을 남기고, 표식 확인과
     * 점수 합산을 한 트랜잭션에 묶는다. 표식에는 등급(rank)을 함께 적어, 같은 발생에
     * 노쇼(추정)와 완주(사실)가 겹치면 사실이 이기고 차액만 보정된다 — 순서 무관 멱등.
     */
    suspend fun applyScore(roomID: String, points: Int, occurrenceKey: String, rank: Int) {
        if (!backendActive || points == 0) return
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return
        val memberRef = db().collection("groups").document(roomID)
            .collection("members").document(myUid)
        val markRef = memberRef.collection("scored").document(markId(occurrenceKey))
        db().runTransaction { txn ->
            val snap = txn.get(markRef)
            var delta = points.toLong()
            if (snap.exists()) {
                val oldRank = snap.getLong("rank")?.toInt() ?: SCORE_RANK_NORMAL
                val oldPoints = snap.getLong("points")?.toInt() ?: 0
                if (rank < oldRank) return@runTransaction null          // 더 확실한 결과가 이미 있다
                if (rank == oldRank && points == oldPoints) return@runTransaction null  // 같은 값 재요청
                delta = (points - oldPoints).toLong()                   // 차액만 보정
            }
            txn.set(markRef, mapOf("points" to points, "rank" to rank, "at" to Timestamp.now()))
            if (delta != 0L) txn.update(memberRef, "score", FieldValue.increment(delta))
            null
        }.await()
    }

    /** 잘못 찍힌 노쇼를 지울 때 그 발생의 반영을 되돌린다. 표식에 적힌 값만큼만 빼고
     *  표식을 지운다 — 이미 완주 등급으로 덮인 표식은 건드리지 않는다(그건 정당한 점수다). */
    fun revokeScore(reservation: Reservation?, occurrenceKey: String) {
        val roomID = reservation?.groupId ?: return
        if (!backendActive) return
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return
        val memberRef = db().collection("groups").document(roomID)
            .collection("members").document(myUid)
        val markRef = memberRef.collection("scored").document(markId(occurrenceKey))
        scoreScope.launch {
            runCatching {
                db().runTransaction { txn ->
                    val snap = txn.get(markRef)
                    if (!snap.exists()) return@runTransaction null
                    val points = snap.getLong("points")?.toInt() ?: return@runTransaction null
                    val oldRank = snap.getLong("rank")?.toInt() ?: SCORE_RANK_NORMAL
                    if (oldRank != SCORE_RANK_NO_SHOW) return@runTransaction null
                    txn.delete(markRef)
                    txn.update(memberRef, "score", FieldValue.increment(-points.toLong()))
                    null
                }.await()
            }
        }
    }

    /**
     * 서버의 내 점수를 표식 합계로 다시 맞춘다. 점수는 더하기로 쌓이는 값이라 트랜잭션이
     * 한 번이라도 실패하면 조용히 어긋난 채 영원히 그대로다 — 표식이 원장이고 점수는 캐시다.
     * `observed`(합계를 세기 전에 읽은 점수)가 트랜잭션 안에서도 그대로일 때만 바꾼다.
     * 달라졌으면 방금 들어온 정당한 점수이므로 이번 보정은 포기한다. 맞춘 경우에만 새 점수 반환.
     */
    suspend fun repairMyScore(roomID: String, observed: Int): Int? {
        if (!backendActive) return null
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return null
        val memberRef = db().collection("groups").document(roomID)
            .collection("members").document(myUid)
        val marks = runCatching {
            memberRef.collection("scored")
                .get(com.google.firebase.firestore.Source.SERVER).await()
        }.getOrNull() ?: return null
        val total = marks.documents.sumOf { (it.getLong("points") ?: 0L).toInt() }
        if (total == observed) return null
        val done = runCatching {
            db().runTransaction { txn ->
                val snap = txn.get(memberRef)
                if (!snap.exists()) return@runTransaction false
                if ((snap.getLong("score") ?: 0L).toInt() != observed) return@runTransaction false
                txn.update(memberRef, "score", total.toLong())
                true
            }.await()
        }.getOrNull() == true
        return if (done) total else null
    }

    // MARK: 탈퇴 · 해체 · 나가기

    /** 시작 전 자유 탈퇴 — 멤버 삭제 + 인원수 감소 */
    suspend fun leaveBeforeStart(context: Context, room: GroupRoom) {
        if (!signedInMember) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.needs_network))
        val roomRef = db().collection("groups").document(room.id)
        val memberRef = roomRef.collection("members").document(uid)
        // 내 닉네임을 takenNicknames에서 풀어 재사용 가능하게(#15) — 삭제 전에 읽어 둔다
        val myNick = runCatching { memberRef.get().await().getString("nickname") }.getOrNull()
        // 핵심 쓰기는 실패를 삼키지 않는다 — 삼키면 '나갔다'고 오해한 채 예약이 남고,
        // 다음 새로고침이 그 방을 여전히 내 방으로 보고 알람을 되살린다.
        memberRef.delete().await()
        val updates = mutableMapOf<String, Any>("memberCount" to FieldValue.increment(-1))
        myNick?.let { updates["takenNicknames"] = FieldValue.arrayRemove(it.lowercase()) }
        runCatching { roomRef.update(updates).await() }
        if (!removeMembershipRef(room.id))
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.left_cleanup_failed))
        removeLocalReservation(context, room.id)   // 미리 만들어 둔 예약 정리
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    /** 시작 후 중도 포기 — 벌점 -50 (그룹 점수 + 개인 누적), 남은 그룹 일정 삭제.
     *  서버 쓰기 실패는 삼키지 않고 던진다 — 삼키면 서버엔 포기가 없는데 로컬만
     *  벌점·예약 삭제가 남아, 다음 새로고침에 방이 되살아나고 재시도마다 개인
     *  벌점이 중복으로 쌓인다 (iOS와 동일한 실패 전파). */
    suspend fun quitAfterStart(context: Context, room: GroupRoom) {
        if (!signedInMember) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.needs_network_retry))
        val memberRef = db().collection("groups").document(room.id)
            .collection("members").document(uid)
        // 벌점을 먼저 넣고 포기 표시를 나중에 한다. 순서가 반대면 중간에 끊겼을 때
        // '포기했는데 벌점은 없는' 상태로 남는다. 둘 다 표식/플래그라 재시도가 채운다.
        // 벌점은 반드시 표식(도장)을 거친다 — 건너뛰면 repairMyScore가 -50을 지운다.
        applyScore(room.id, ScoreRules.GROUP_QUIT_PENALTY,
            quitOccurrenceKey(room.id), SCORE_RANK_NORMAL)
        memberRef.update("quit", true).await()
        // 개인 누적에도 동일 벌점 기록
        val event = ScoreEvent(
            ownerUserID = uid, typeRaw = ScoreEventType.GROUP_QUIT.raw,
            points = ScoreRules.GROUP_QUIT_PENALTY, sessionID = null,
            intensityRaw = room.intensityRaw, note = ScoreNote.groupGiveup(room.name))
        AppDb.get(context).scores().insert(event)
        AccountStore.mirror(event)
        removeLocalReservation(context, room.id)
        // groupIDs 정리 실패를 무시하면 안 된다 — 방이 목록에 유령으로 남아 보존 만료까지
        // 계속 보인다. quit 표시는 이미 서버에 남았으므로 재시도해도 벌점이 중복되지 않는다.
        if (!removeMembershipRef(room.id))
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.quit_cleanup_failed))
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    /** 방장 전용, 시작 전 해체 — 참여자들은 다음 새로고침에서 안내를 받는다 */
    suspend fun disband(context: Context, room: GroupRoom) {
        if (!signedInMember) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.needs_network))
        if (!room.isHostMine) throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.host_only_disband))
        // 서버 상태 재확인 — 로컬 스냅샷이 낡았을 수 있다. 이미 시작한 방을 해체하면
        // 참여자들의 진행 중 벌점·기록이 통째로 무효가 되는 회피 경로가 열린다.
        val live = runCatching {
            db().collection("groups").document(room.id)
                .get(com.google.firebase.firestore.Source.SERVER).await()
        }.getOrNull() ?: throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.room_state_check_failed))
        val liveStatus = live.getString("status") ?: "scheduled"
        val liveStart = live.getTimestamp("startDate")?.toDate()?.time ?: room.startDate
        if (liveStatus != "scheduled" || System.currentTimeMillis() >= liveStart)
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.cannot_disband_started))
        db().collection("groups").document(room.id).update("status", "disbanded").await()
        removeMembershipRef(room.id)
        // 방장 자신의 멤버 문서 정리 — 혼자였던 방이면 문서까지 즉시 삭제,
        // 참여자가 있으면 status로 해체를 알린 뒤 마지막 참여자가 문서를 지운다
        cleanupDisbandedRoom(room.id, uid)
        removeLocalReservation(context, room.id)   // 미리 만들어 둔 예약 정리
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    /** 종료된 방 '나가기' — 내 목록에서만 사라진다 (다른 참여자의 결과는 유지) */
    suspend fun hideFinishedRoom(context: Context, room: GroupRoom) {
        if (!removeMembershipRef(room.id))
            throw GroupException(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.operation_failed_network))
        // 끝난 방이라도 로컬 예약은 남아 일정·홈에 계속 뜬다 — 반드시 함께 정리한다.
        removeLocalReservation(context, room.id)
        rooms.value = rooms.value.filterNot { it.id == room.id }
        AlarmScheduler.rescheduleAll(context)
    }

    // MARK: 내부

    /** 활성 방의 그룹 예약이 내 기기에 없으면 만든다.
     *  createdAt을 방 시작일로 두어, 앱을 늦게 열어도 시작일 이후의 노쇼가 전부 집계된다. */
    private suspend fun ensureLocalReservation(context: Context, room: GroupRoom) {
        val dao = AppDb.get(context).reservations()
        val owner = AccountStore.currentUserID
        val stableId = stableReservationId(room.id, owner)
        val existing = dao.byGroup(owner, room.id).firstOrNull { it.isActive }
        if (existing != null) {
            // 과거 버전이 무작위 ID로 만든 예약 — 결정적 ID로 옮기고 딸린 세션도 갱신
            if (existing.id != stableId) migrateReservationId(context, existing, stableId)
            return
        }
        // 일회성 그룹(요일 없음)은 방 시작일 하루만 발생 → oneOffDayStart 지정
        val oneOff = if (room.repeatWeekdays.isEmpty()) {
            java.util.Calendar.getInstance().apply {
                timeInMillis = room.startDate
                set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
        } else null
        dao.upsert(Reservation(
            id = stableId,
            ownerUserID = owner, name = room.name, tag = CanonicalTag.GROUP,
            startMinute = room.startMinute, durationMinutes = room.durationMinutes,
            repeatWeekdaysCsv = room.repeatWeekdays.joinToString(","),
            oneOffDayStart = oneOff,
            createdAt = room.startDate,
            groupId = room.id, endAt = room.endDate,
            intensityOverrideRaw = room.intensityRaw,
        ))
    }

    /** 무작위 ID 그룹 예약을 결정적 ID로 이관 — 세션의 reservationID와 클라우드 요약까지
     *  함께 갱신해야 발생 키가 하나로 모인다. */
    private suspend fun migrateReservationId(context: Context, old: Reservation, stableId: String) {
        val db = AppDb.get(context)
        for (sess in db.sessions().all(old.ownerUserID)) {
            if (sess.reservationID != old.id) continue
            val moved = sess.copy(reservationID = stableId)
            db.sessions().upsert(moved)
            AccountStore.mirrorSession(moved)
        }
        AlarmScheduler.cancel(context, old.id)
        db.reservations().delete(old)
        db.reservations().upsert(old.copy(id = stableId))
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
                    for (e in dbLocal.scores().bySession(session.id)) {
                        // 클라우드 사본까지 지워야 다음 동기화에서 되살아나지 않는다
                        AccountStore.deleteMirroredEvent(e.ownerUserID, e.id)
                        dbLocal.scores().delete(e)
                    }
                    // 세션도 클라우드 사본(sessionSummaries)까지 지운다 — 로컬만 지우면
                    // 다음 동기화가 노쇼 세션을 되살려 연속 달성일이 매번 끊긴다 (불변식 #4)
                    AccountStore.deleteMirroredSession(session.ownerUserID, session.id)
                    dbLocal.sessions().delete(session)
                }
            }
            // 예약만 지우고 알람을 그대로 두면, 예약이 없는 채로 알람이 울려
            // 라우팅 대상이 없는 검은 화면 + 끌 수 없는 소리가 된다. 반드시 먼저 취소.
            AlarmScheduler.cancel(context, reservation.id)
            // 폭파·취소·해체된 그룹 예약은 DB에서 완전 삭제 (소프트 삭제 아님) —
            // 방 문서가 사라졌으니 재생성되지 않는다.
            dbLocal.reservations().delete(reservation)
        }
    }

    /** 내가 속한 방 ID 목록. null = 조회 실패(네트워크 등) — '가입한 방 없음'(빈 목록)과
     *  반드시 구분해야 한다. 실패를 빈 목록으로 뭉개면 고아 예약 스윕이 멀쩡한 예약을 전부 지운다. */
    private suspend fun myRoomIDs(): List<String>? {
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return null
        // getDocument는 문서가 없어도 성공한다(빈 스냅샷). 소스를 지정하지 않으면 로컬
        // 캐시로도 답하므로, 새 기기·재설치처럼 캐시가 빈 상태를 '가입한 방 0개'로 읽어
        // 멀쩡한 그룹 활동이 전부 삭제된다 (iOS에서 실제로 났던 사고).
        // 서버에서 읽고, 문서가 없으면 '모름'(null)으로 돌려 이번 새로고침을 건너뛴다.
        val doc = runCatching {
            db().collection("users").document(myUid)
                .get(com.google.firebase.firestore.Source.SERVER).await()
        }.getOrNull() ?: return null
        if (!doc.exists()) return null
        @Suppress("UNCHECKED_CAST")
        return doc.get("groupIDs") as? List<String> ?: emptyList()
    }

    /** 고아 그룹 예약 정리 — 서버 기준 내 방 목록에 없는 groupId의 로컬 예약을 제거한다.
     *  나가기·해체·중도포기 중 어느 경로가 실패해 예약이 남아도 다음 새로고침에서 자가 치유된다.
     *  (호출 측에서 '조회 성공'이 보장된 ID 목록만 넘길 것) */
    private suspend fun pruneOrphanGroupReservations(context: Context, liveRoomIDs: Set<String>) {
        val dao = AppDb.get(context).reservations()
        val owner = AccountStore.currentUserID
        for (r in dao.allForOwner(owner)) {
            val gid = r.groupId ?: continue
            if (gid in liveRoomIDs) continue
            AlarmScheduler.cancel(context, r.id)   // 예약만 지우면 유령 알람이 남는다
            dao.delete(r)
        }
    }

    /** 실패를 삼키면 안 된다 — groupIDs에 방이 남으면 다음 새로고침이 그 방을 여전히
     *  '내 방'으로 보고 예약을 다시 만들어 알람이 되살아난다. 성공 여부를 돌려준다. */
    private suspend fun removeMembershipRef(roomID: String): Boolean {
        val myUid = uid
        if (myUid.isEmpty() || myUid == "guest") return false
        return runCatching {
            db().collection("users").document(myUid)
                .set(mapOf("groupIDs" to FieldValue.arrayRemove(roomID)),
                    com.google.firebase.firestore.SetOptions.merge()).await()
        }.isSuccess
    }

    // MARK: '진행을 목격한 방' 마커 — 방 문서가 사라진 이유(시작 전 정리 vs 보존 만료)를 구분

    private fun markRoomActive(id: String) {
        if (id !in Prefs.seenActiveRoomIDs) Prefs.seenActiveRoomIDs = Prefs.seenActiveRoomIDs + id
    }

    private fun forgetRoomActive(id: String) {
        if (id in Prefs.seenActiveRoomIDs) Prefs.seenActiveRoomIDs = Prefs.seenActiveRoomIDs - id
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
