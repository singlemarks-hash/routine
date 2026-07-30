package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.models.ActivityTag
import com.singlemarks.angrymoti.models.DayOutcome
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScheduleConflict
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.models.TimePolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.AlarmScheduler
import com.singlemarks.angrymoti.services.SubscriptionManager
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Calendar

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReservationEditScreen(reservationId: String?, onDone: () -> Unit) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    val scope = rememberCoroutineScope()
    val owner = AccountStore.currentUserID
    val isPro by SubscriptionManager.isPro.collectAsState()
    val insaneUnlocked = isPro   // 미친맛: 멤버십 전용 (유료 확정)

    var loaded by remember { mutableStateOf(reservationId == null) }
    var existing by remember { mutableStateOf<Reservation?>(null) }
    var name by remember { mutableStateOf("") }
    var tag by remember { mutableStateOf(ActivityTag.presets.first()) }
    var customTag by remember { mutableStateOf("") }
    var startMinute by remember { mutableStateOf(TimePolicy.defaultStartMinute()) }
    var durationMinutes by remember { mutableStateOf(60) }
    var intensity by remember { mutableStateOf(com.singlemarks.angrymoti.AppState.intensity.value) }
    var weeklyRepeat by remember { mutableStateOf(false) }          // 요일 반복 토글 (ON=고른 요일, OFF=매일)
    var repeatDays by remember { mutableStateOf(setOf<Int>()) }     // 요일 반복 ON일 때 고른 요일
    var oneOffDay by remember { mutableStateOf<Long?>(null) }        // 시작일 (두 모드 공통)
    var noEndDate by remember { mutableStateOf(true) }              // '종료일 없음' (기본 켜짐 = 무기한)
    var oneOffEndDay by remember { mutableStateOf<Long?>(null) }    // '종료일'
    var error by remember { mutableStateOf<String?>(null) }
    var showSlotSheet by remember { mutableStateOf(false) }
    var showPaywall by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }
    var showDurationMenu by remember { mutableStateOf(false) }
    var showDatePicker by remember { mutableStateOf(false) }
    var showEndDatePicker by remember { mutableStateOf(false) }
    var allSessions by remember { mutableStateOf(listOf<com.singlemarks.angrymoti.data.FocusSession>()) }
    var allReservations by remember { mutableStateOf(listOf<Reservation>()) }

    LaunchedEffect(reservationId) {
        withContext(Dispatchers.IO) {
            allSessions = db.sessions().all(owner)
            allReservations = db.reservations().active(owner)
            reservationId?.let { id ->
                db.reservations().byId(id)?.let { r ->
                    existing = r
                    name = r.name; startMinute = r.startMinute
                    durationMinutes = r.durationMinutes
                    // oneOffDayStart 마커가 있으면 '매일(기간/단발성)' 모드, 없으면 '요일 반복' 모드.
                    // 기간(시작일·종료일)은 두 모드 공통이므로 항상 복원한다.
                    val hasDate = r.oneOffDayStart != null
                    weeklyRepeat = !hasDate                     // 마커 없음 = 요일 반복 토글 ON
                    repeatDays = r.repeatWeekdays.toSet()       // 요일 반복 모드에서만 UI에 노출
                    // 시작일: 매일 모드는 마커, 요일 반복 모드는 시작 게이트(createdAt)
                    oneOffDay = r.oneOffDayStart ?: startOfDayLocal(r.createdAt)
                    if (hasDate && !r.isRepeating) {
                        // 레거시 단발성 → 시작일=종료일 하루로 표시
                        noEndDate = false
                        oneOffEndDay = r.oneOffDayStart
                    } else {
                        noEndDate = (r.endAt == null)
                        oneOffEndDay = r.endAt?.let { startOfDayLocal(it) } ?: oneOffDay
                    }
                    intensity = r.intensityOverride ?: com.singlemarks.angrymoti.AppState.intensity.value
                    if (r.tag in ActivityTag.presets) tag = r.tag else customTag = r.tag
                }
            }
            // 신규 생성만 미친맛 미해제 시 매운맛으로 (전역 기본이 미친맛이어도).
            // 기존 예약은 저장된 값을 그대로 보여준다 — 예전에는 미해제 상태에서 열면 화면을
            // 매운맛으로 내려놓고, 이름만 고쳐 저장해도 그 매운맛이 기록돼 원래 설정이 지워졌다.
            // (미친맛 버튼은 미해제면 어차피 눌리지 않으므로 새로 고를 수는 없다)
            if (existing == null && !insaneUnlocked && intensity == Intensity.INSANE) intensity = Intensity.SPICY
            loaded = true
        }
    }
    if (!loaded) return
    if (showPaywall) { PaywallScreen(onBack = { showPaywall = false }); return }

    // 전체 세션 스트릭 루프·예약×180일 발생 스캔은 무겁다 — 입력 한 글자마다(리컴포지션)
    // 다시 돌지 않게 캐시한다. 화면이 열려 있는 동안 데이터가 바뀔 일은 저장뿐이다.
    val streak = remember(allSessions) { SlotPolicy.currentStreak(allSessions) }
    val allowed = SlotPolicy.allowedSlots(streak, isPro)
    // 끝난 활동은 슬롯을 차지하지 않는다 (iOS slotUsingReservations와 동일)
    val used = remember(allReservations) { allReservations.count { it.hasRemainingOccurrence() } }
    val slotFull = allowed != null && used >= allowed && existing == null

    // 편집 잠금 창: 발생 30분 전 ~ 발생 +10분(노쇼 확정 시점). 정각에 풀리면 알람을 놓친
    // 직후(스윕 전 10분 안에) 예약을 아무거나 고쳐 저장해 accountableFrom을 갱신, 방금
    // 노쇼를 면책하는 회피 경로가 열린다 — 스윕이 확정하기 전까진 어떤 편집도 막는다 (iOS 1:1).
    val isLocked = existing?.let { r ->
        val nowMs = System.currentTimeMillis()
        val next = r.nextOccurrence()
        if (next != null && next - nowMs <= 30 * 60_000L) return@let true
        val today = DayOutcome.startOfDay(nowMs)
        listOf(ScheduleConflict.addDays(today, -1), today).any { day ->
            r.occurrenceOn(day)?.let { fire ->
                fire <= nowMs && nowMs - fire <= TimePolicy.START_WINDOW_SECONDS * 1000
            } == true
        }
    } == true

    /** 슬롯 초과(강등·연속 하락) — 보유 예약이 허용치를 넘으면 편집 잠그고 삭제만 허용(읽기 전용) */
    val overSlotLimit = allowed != null && used > allowed
    /** 미친 매운맛으로 만든 활동인데 지금은 그 등급을 쓸 수 없는 상태(멤버십 만료 등).
     *  강도를 임의로 내리면 이미 쌓인 2배 벌점 기준이 바뀌므로 그대로 유지하고,
     *  조회와 삭제만 허용한다. (다시 쓰려면 멤버십을 복구하면 된다) */
    val lockedInsane = existing?.intensityOverride == Intensity.INSANE && !insaneUnlocked
    val editReadOnly = existing != null && (overSlotLimit || lockedInsane)
    /** 은퇴한 예약 — 삭제(오늘로 은퇴) 또는 자연 종료로 앞으로 발생이 없다.
     *  일정 탭에는 오늘 자정까지만 남는 '보여주기 전용' 상태다. 편집·저장은 물론
     *  삭제 버튼도 잠근다 — 이미 삭제(종료)된 것을 또 삭제할 수는 없고, 여기서
     *  무언가를 바꿀 수 있으면 은퇴로 닫아둔 노쇼 집계·기록 정합이 다시 열린다 (iOS 1:1). */
    val isRetired = existing?.hasRemainingOccurrence() == false
    /** 입력 필드·저장 잠금 = 시작 임박 ∨ 읽기 전용 ∨ 은퇴 (삭제는 은퇴만 잠금) */
    val fieldLocked = isLocked || editReadOnly || isRetired

    /** 이미 시작한 활동은 시작일을 바꿀 수 없다.
     *
     *  시작일은 그대로 createdAt(발생 시작 게이트)에 저장되는데, 노쇼 복구 루틴이
     *  'scheduledAt < createdAt인 노쇼는 잘못된 기록'으로 보고 세션·벌점을 지운다.
     *  시작일을 자유롭게 미룰 수 있으면 그 이전의 정당한 벌점이 전부 삭제되는 회피
     *  경로가 열린다. 첫 발생이 이미 지났다면(=노쇼가 생길 수 있었다면) 잠근다.
     *  아직 시작 전인 예약은 지울 기록 자체가 없으므로 자유롭게 바꿔도 안전하다. */
    val startDateLocked = existing?.let { lockedStartDay(it) != null } == true

    val timeState = rememberTimePickerState(
        initialHour = startMinute / 60, initialMinute = startMinute % 60, is24Hour = false)

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TLPillButton("닫기", tint = TL.paper, onClick = onDone)
            Spacer(Modifier.weight(1f))
            Text(if (existing == null) "활동 예약" else "예약 편집",
                color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f))
            // 은퇴한 예약은 저장 버튼 자체가 없다 — 보여주기 전용 (iOS 1:1)
            if (!isRetired) TLPillButton("저장", tint = TL.rec, enabled = !fieldLocked, onClick = save@{
                    // 검증 — 오류는 최상단에 즉시 표시
                    val finalName = name.trim()
                    val finalTag = customTag.trim().ifEmpty { tag }
                    val sm = timeState.hour * 60 + timeState.minute
                    // 읽기 전용 — 편집 저장 차단(삭제만 허용). 버튼도 비활성이지만 백스톱.
                    if (editReadOnly) {
                        error = if (lockedInsane)
                            "미친 매운맛 활동은 지금 편집할 수 없어요. 조회와 삭제만 가능합니다."
                        else
                            "슬롯 한도를 초과해 편집이 잠겼어요. 예약을 삭제해 슬롯 수 이내로 정리하면 다시 편집할 수 있어요."
                        return@save
                    }
                    if (finalName.isEmpty()) { error = "활동명을 입력해주세요."; return@save }
                    if (slotFull) { error = "활동 슬롯이 가득 찼어요. 연속 달성일을 쌓으면 슬롯이 늘어나요."; return@save }

                    // 기간(시작일·종료일)은 요일 반복·매일 공통. 요일 반복 OFF면 매일(요일 전체).
                    // 잠긴 예약(이미 시작함)은 UI가 시작일을 못 바꾸게 하지만, 저장 경로에서도
                    // 한 번 더 실제 발생 시작일을 강제한다 — 시작 게이트가 움직이면 노쇼 복구
                    // 루틴이 과거의 정당한 벌점을 지워버린다.
                    val startDay = existing?.let { lockedStartDay(it) }
                        ?: (oneOffDay ?: nextOneOffDay(sm))      // 시작일(자정)
                    // 종료일은 화면 값을 그대로 쓴다 — 시작일로 끌어붙이는 보정(coerceAtLeast)을
                    // 쓰면 시작일=종료일이 되어 요일 반복 UI가 사라지고, 저장 시 고른 요일이
                    // 전체 요일로 덮여 월·수·금 반복이 조용히 매일로 바뀐다. 시작일 픽커가
                    // 기간 길이를 보존해 종료일을 함께 밀어주므로 여기선 검증만 한다.
                    val endDayNorm = startOfDayLocal(oneOffEndDay ?: startDay)
                    // 시작일=종료일이면 그날 하루뿐이라 요일 반복이 무의미 — 항상 전체 요일로 저장.
                    val isSingleDay = !noEndDate && endDayNorm == startDay
                    val isWeekly = weeklyRepeat && !isSingleDay
                    // 검증: 요일 반복이면 요일 최소 1개 (하루짜리는 요일 반복 UI가 없으므로 제외)
                    if (isWeekly && repeatDays.isEmpty()) { error = "반복할 요일을 선택하세요."; return@save }
                    // 검증: 시작일 상한 (신규 생성만). 기존 예약은 상한 도입 전에 만들어진 먼
                    // 시작일을 가질 수 있는데, 이름만 고치는 정상 편집까지 막으면 손댈 방법이 없다.
                    if (existing == null &&
                        startDay > com.singlemarks.angrymoti.models.ReservationPolicy.maxStartDayMillis()) {
                        error = "시작일은 오늘부터 ${com.singlemarks.angrymoti.models.ReservationPolicy.MAX_START_LEAD_MONTHS}개월 이내로 정해주세요."
                        return@save
                    }
                    // 검증: 종료일 지정 시 — 종료일 ≥ 시작일 · 아직 안 지남 (두 모드 공통)
                    if (!noEndDate) {
                        if (endDayNorm < startDay) { error = "종료일은 시작일 이후여야 해요."; return@save }
                        if (endDayNorm < todayStart()) { error = "종료일이 이미 지났어요."; return@save }
                    }
                    val resolvedDays = if (isWeekly) repeatDays else setOf(1, 2, 3, 4, 5, 6, 7)
                    val resolvedDaysCsv = resolvedDays.sorted().joinToString(",")
                    val resolvedOneOff = if (isWeekly) null else startDay   // 매일·하루 모드는 시작일 마커
                    val resolvedEnd = if (!noEndDate) endDayNorm + 86_400_000L - 1 else null

                    // 검증 A: 이 설정이 애초에 성립하는가 — 기간 '전체'에 고른 요일이 한 번이라도
                    // 오는가. (예: 월~수 기간에 금·토를 고르면 평생 울리지 않는다)
                    // 기준을 '남은 발생'이 아니라 '기간 전체'로 잡아야, 마지막 날을 앞둔 예약의
                    // 이름만 고치는 정상 편집이 막히지 않는다. 요일은 7개뿐이라 8일이면 판정된다.
                    val conflictRule = com.singlemarks.angrymoti.models.ScheduleConflict
                    var anyOccurrence = false
                    for (offset in 0..8) {
                        val day = conflictRule.addDays(startDay, offset)
                        if (resolvedEnd != null && day > resolvedEnd) break
                        if (Calendar.getInstance().apply { timeInMillis = day }
                                .get(Calendar.DAY_OF_WEEK) in resolvedDays) { anyOccurrence = true; break }
                    }
                    if (!anyOccurrence) {
                        error = "선택한 기간 안에 고른 요일이 없어요. 요일이나 기간을 조정해주세요."
                        return@save
                    }

                    // 검증 B: 신규 생성은 앞으로 울릴 발생이 남아 있어야 한다.
                    // (예: 밤 8시에 '오늘 아침 8시 하루'를 만들면 태어날 때부터 죽은 예약)
                    // 기존 예약 편집에는 적용하지 않는다 — 마지막 날을 지나가는 중인 예약도
                    // 이름 수정·조기 종료 같은 정상 편집이 가능해야 한다.
                    if (existing == null) {
                        var futureOccurrence = false
                        val scanStart = maxOf(startDay, todayStart())
                        for (offset in 0..8) {
                            val day = conflictRule.addDays(scanStart, offset)
                            if (resolvedEnd != null && day > resolvedEnd) break
                            if (Calendar.getInstance().apply { timeInMillis = day }
                                    .get(Calendar.DAY_OF_WEEK) !in resolvedDays) continue
                            if (day + sm * 60_000L > System.currentTimeMillis()) { futureOccurrence = true; break }
                        }
                        if (!futureOccurrence) {
                            error = "이미 지난 시각이에요. 시작 시각이나 날짜를 조정해주세요."
                            return@save
                        }
                    }

                    // 검증: 실제로 부딪히는 예약만 차단 — 기간이 겹치고, 그 안에서 같은
                    // 요일·시간대일 때 (자정 넘김 꼬리 포함). 기간을 안 보면 이미 끝난 활동이
                    // 새 활동을 영영 막고, 날짜가 다른 하루짜리끼리도 충돌로 잡힌다.
                    val myHi = resolvedEnd?.let { startOfDayLocal(it) }
                    val clashing = allReservations.firstOrNull { other ->
                        if (other.id == existing?.id) return@firstOrNull false
                        val (bLo, bHi) = other.activeDayRange()
                        conflictRule.conflicts(
                            startDay, myHi, resolvedDays, sm, durationMinutes,
                            bLo, bHi, other.occupiedWeekdays(), other.startMinute, other.durationMinutes)
                    }
                    if (clashing != null) {
                        error = "${TLFormat.timeLabel(clashing.startMinute)} '${clashing.name}' 예약과 시간이 겹칩니다."
                        return@save
                    }

                    scope.launch(Dispatchers.IO) {
                        // 일정에 실질 변화가 있는 편집인가 — 이름·태그·강도만 고친 저장으로
                        // accountableFrom이 갱신되면 그 자체가 노쇼 면책 수단이 된다 (iOS 1:1).
                        // (existing은 위임 프로퍼티라 스마트캐스트 불가 — 로컬로 캡처)
                        val prev = existing
                        val scheduleChanged = prev == null ||
                            prev.startMinute != sm ||
                            prev.durationMinutes != durationMinutes ||
                            prev.repeatWeekdaysCsv != resolvedDaysCsv ||
                            prev.oneOffDayStart != resolvedOneOff ||
                            prev.endAt != resolvedEnd ||
                            prev.createdAt != startDay
                        val r = (prev ?: Reservation(
                            ownerUserID = owner, name = finalName, tag = finalTag,
                            startMinute = sm, durationMinutes = durationMinutes,
                        )).copy(
                            name = finalName, tag = finalTag, startMinute = sm,
                            durationMinutes = durationMinutes,
                            repeatWeekdaysCsv = resolvedDaysCsv,
                            oneOffDayStart = resolvedOneOff,
                            endAt = resolvedEnd,
                            intensityOverrideRaw = intensity.raw,   // 활동별 강도
                            // 시작일 = 발생 시작 게이트(createdAt). 잠긴(이미 시작한) 예약은
                            // startDay가 기존 값과 같으므로 실질적으로 불변이다.
                            createdAt = startDay,
                            // 책임 기준은 '지금'과 '시작일' 중 늦은 쪽.
                            // 시작일 자정으로 두면 오늘 만든 예약이 오늘 아침 발생분까지 소급
                            // 노쇼로 잡힌다(토 16시에 만든 매일 06:00 예약이 -15점 받던 결함).
                            // 단, 시각·요일·기간이 실제로 바뀐 편집에만 갱신 — 이름만 고친
                            // 저장은 책임 기준을 건드리지 않는다(잠금 창과 이중 방어).
                            accountableFrom = if (scheduleChanged)
                                maxOf(System.currentTimeMillis(), startDay)
                            else prev!!.accountableFrom,
                            updatedAt = System.currentTimeMillis(),
                        )
                        db.reservations().upsert(r)
                        AccountStore.mirrorReservation(r)   // 크로스 기기 동기화
                        r.nextOccurrence()?.let { AlarmScheduler.scheduleExact(context, r.id, it) }
                        withContext(Dispatchers.Main) { onDone() }
                    }
                })
            else Box(Modifier.alpha(0f)) {   // 자리만 지키는 투명 필 — 타이틀 중앙 유지
                TLPillButton("저장", enabled = false, onClick = {})
            }
        }

        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            error?.let {
                Text(it, color = TL.rec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.rec.copy(alpha = 0.12f), TL.cornerM).padding(12.dp))
            }
            if (isRetired) {
                // 은퇴 안내 하나만 — 다른 잠금 사유는 의미 없음 (iOS retiredNotice 1:1)
                Text("이 활동은 삭제(종료)되어 더 이상 수정할 수 없습니다. 오늘 기록 확인용으로 자정까지만 일정에 표시되고, 이후에는 목록에서 사라집니다. 지난 기록은 기록 탭에서 계속 볼 수 있어요.",
                    color = TL.amber, fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.amber.copy(alpha = 0.12f), TL.cornerM).padding(12.dp))
            }
            if (isLocked && !isRetired) {
                Text("시작 30분 전에는 편집할 수 없어요", color = TL.amber, fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.amber.copy(alpha = 0.12f), TL.cornerM).padding(12.dp))
            }
            if (editReadOnly && !isRetired) {
                Text(
                    if (lockedInsane)
                        "미친 매운맛으로 만든 활동이에요. 지금은 그 등급을 쓸 수 없어 조회와 삭제만 할 수 있습니다. 강도를 임의로 내리면 이미 쌓인 2배 기준이 바뀌므로 그대로 둡니다."
                    else
                        "활동 슬롯이 ${allowed}개로 줄어 보유한 예약이 한도를 넘었어요. 초과한 동안에는 편집이 잠기고 삭제만 할 수 있어요. 예약을 슬롯 수 이내로 정리하거나 멤버십·연속 달성으로 슬롯을 늘리면 다시 편집할 수 있어요.",
                    color = TL.amber, fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.amber.copy(alpha = 0.12f), TL.cornerM).padding(12.dp))
            }

            // 활동 슬롯 현황 — 터치하면 정책 표 팝업
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
                    .background((if (slotFull) TL.amber else TL.jade).copy(alpha = 0.10f), TL.cornerM)
                    .clickable { showSlotSheet = true }.padding(12.dp),
            ) {
                Text(if (slotFull) "🔒" else "🔥", fontSize = 14.sp)
                Spacer(Modifier.width(10.dp))
                Column {
                    Text("활동 슬롯 $used/${allowed?.toString() ?: "무제한"} · 연속 달성 ${streak}일",
                        color = TL.paper, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                    Text("터치하면 슬롯 정책을 볼 수 있어요", color = TL.faint, fontSize = 11.sp)
                }
                Spacer(Modifier.weight(1f))
                Text("ⓘ", color = TL.muted, fontSize = 15.sp)
            }

            // ── 활동명 (필수, 빨간 별표) — 큰 서피스 입력 필드, 항상 테두리 (iOS 1:1)
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TLEyebrow("활동명")
                    Spacer(Modifier.width(4.dp))
                    Text("*", color = TL.rec, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(bottom = 8.dp))
                }
                TLField(name, { name = it.take(ActivityTag.NAME_MAX_LENGTH) },
                    "예: 기출문제 3회분", enabled = !fieldLocked,
                    unfocusedBorderColor = TL.hairline.copy(alpha = 0.6f))
            }

            // ── 태그 — 프리셋 칩(직접 입력 중에도 항상 선택 가능) + '직접 입력' 필드 (iOS 1:1)
            Column {
                TLEyebrow("태그")
                val customTagActive = customTag.isNotBlank()
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.alpha(if (customTagActive) 0.55f else 1f),
                ) {
                    items(ActivityTag.presets.size) { i ->
                        val p = ActivityTag.presets[i]
                        TagChip(p, !customTagActive && tag == p) {
                            if (!fieldLocked) { tag = p; customTag = "" }
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                TLField(customTag, { customTag = ActivityTag.truncatedToTagWidth(it) },
                    "직접 입력 (선택)", enabled = !fieldLocked,
                    unfocusedBorderColor = if (customTagActive) TL.hairline.copy(alpha = 0.6f) else Color.Transparent)
            }

            // ── 강도 — 활동별 설정 (그룹 방 만들기와 동일, 혼자 하는 활동이라 '참여자 전원' 문구 제거)
            // 미친 매운맛은 멤버십 전용 — 잠금 아이콘만으로 충분히 전달되므로 별도 '멤버십
            // 전용' 표기는 하지 않는다. 무료 회원(게스트 제외)이 누르면 가입 페이지로 보낸다.
            Column {
                TLEyebrow("강도")
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Intensity.entries.forEach { level ->
                        val selected = intensity == level
                        val locked = level == Intensity.INSANE && !insaneUnlocked
                        Column(
                            Modifier.weight(1f)
                                .background(if (selected) TL.paper else TL.surface, TL.cornerM)
                                .alpha(if (locked) 0.7f else 1f)
                                .clickable(enabled = if (locked) true else !fieldLocked) {
                                    if (locked) {
                                        if (AccountStore.isSignedIn && AccountStore.currentUserID != "guest") {
                                            showPaywall = true
                                        }
                                    } else intensity = level
                                }
                                .padding(vertical = 10.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text((if (locked) "🔒 " else "") + "${level.emoji} ${level.title}",
                                color = if (selected) TL.ink else TL.muted,
                                fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            Text(if (level == Intensity.SPICY) "최대 10분 긴급용무 허용" else "봐주기 없는 100% 몰입, 점수 2배",
                                color = if (selected) TL.ink.copy(alpha = 0.7f) else TL.faint, fontSize = 10.sp)
                        }
                    }
                }
            }

            // ── 몇시에 얼마나 진행하나요? — 시작 시각 pill(탭→인라인 피커) + 길이 드롭다운 + 완주 상점
            Column {
                TLEyebrow("몇시에 얼마나 진행하나요?")
                TLCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("시작 시각", color = TL.paper, fontSize = 16.sp)
                        Spacer(Modifier.weight(1f))
                        Text(TLFormat.timeLabel(timeState.hour * 60 + timeState.minute),
                            color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.background(TL.raised, CircleShape)
                                .clickable(enabled = !fieldLocked) { showTimePicker = !showTimePicker }
                                .padding(horizontal = 16.dp, vertical = 9.dp))
                    }
                    if (showTimePicker) {
                        Spacer(Modifier.height(10.dp))
                        TimePicker(state = timeState)
                    }
                    Spacer(Modifier.height(14.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.clickable(enabled = !fieldLocked) { showDurationMenu = true }
                                    .padding(vertical = 2.dp),
                            ) {
                                Text(TLFormat.durationLabel(durationMinutes),
                                    color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                                Spacer(Modifier.width(6.dp))
                                androidx.compose.material3.Icon(AppIcon.ChevronsUpDown, null,
                                    tint = TL.muted, modifier = Modifier.size(15.dp))
                            }
                            androidx.compose.material3.DropdownMenu(
                                expanded = showDurationMenu,
                                onDismissRequest = { showDurationMenu = false },
                                containerColor = TL.raised,
                            ) {
                                TimePolicy.durationOptionsMinutes.forEach { m ->
                                    androidx.compose.material3.DropdownMenuItem(
                                        text = {
                                            Text(TLFormat.durationLabel(m),
                                                color = if (m == durationMinutes) TL.paper else TL.muted,
                                                fontWeight = if (m == durationMinutes) FontWeight.Bold else FontWeight.Normal)
                                        },
                                        onClick = { durationMinutes = m; showDurationMenu = false })
                                }
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        Text("완료 시 +${ScoreRules.completionBase(durationMinutes)}점",
                            color = TL.jade, fontSize = 13.sp, fontWeight = FontWeight.Black,
                            modifier = Modifier.background(TL.jade.copy(alpha = 0.16f), CircleShape)
                                .padding(horizontal = 12.dp, vertical = 6.dp))
                    }
                }
            }

            // ── 반복 — 기간(시작일·종료일) 먼저, 그 다음 요일 반복(ON=고른 요일, OFF=매일) (iOS 1:1)
            Column {
                TLEyebrow("반복")
                TLCard {
                    val startDayVal = oneOffDay ?: nextOneOffDay(timeState.hour * 60 + timeState.minute)
                    // 종료일을 시작일로 끌어붙이지 않고 실제 값을 그대로 보여준다 — 붙이면
                    // 시작일=종료일이 되어 요일 반복 UI가 사라지고 반복이 매일로 덮인다.
                    val endDayVal = oneOffEndDay ?: startDayVal
                    // 시작일=종료일이면 그날 하루뿐이라 요일 반복 설정 자체가 무의미하다
                    // (그 요일이 빠지면 발생이 0번이 되는 모순도 막는다) — 이 경우 요일 반복 UI를 숨긴다.
                    val isSingleDay = !noEndDate && startOfDayLocal(startDayVal) == startOfDayLocal(endDayVal)

                    // 기간 — 시작일부터 정하고, 그 기간에 요일 반복을 적용할지 고른다.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("시작일", color = TL.paper, fontSize = 16.sp)
                        Spacer(Modifier.weight(1f))
                        if (startDateLocked) {
                            // 이미 시작한 활동은 읽기 전용 — 시작 게이트가 움직이면 지난 기록이 지워진다
                            Text(dateLabel(startDayVal), color = TL.muted, fontSize = 15.sp)
                        } else {
                            Text(dateLabel(startDayVal), color = TL.paper, fontSize = 15.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.background(TL.raised, CircleShape)
                                    .clickable(enabled = !fieldLocked) { showDatePicker = true }
                                    .padding(horizontal = 16.dp, vertical = 9.dp))
                        }
                    }
                    if (startDateLocked) {
                        Spacer(Modifier.height(6.dp))
                        Text("이미 시작한 활동이라 시작일은 바꿀 수 없어요. 지난 기록과 점수를 지키기 위한 제한이에요.",
                            color = TL.faint, fontSize = 12.sp, lineHeight = 17.sp)
                    }
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("종료일 없음", color = TL.paper, fontSize = 16.sp)
                        Spacer(Modifier.weight(1f))
                        Switch(
                            checked = noEndDate,
                            onCheckedChange = { on ->
                                if (fieldLocked) return@Switch
                                noEndDate = on
                                // 종료일을 켜는 순간의 보정. 하한은 '시작일'이 아니라 '시작일과
                                // 오늘 중 늦은 쪽' — 무기한 예약은 종료일 값이 시작일(과거)로
                                // 채워져 있어, 시작일에만 맞추면 이미 지난 날짜가 그대로 남는다.
                                // 요일 반복 중이면 종료일을 시작일에 붙이면 안 된다. 붙는 순간
                                // 시작일=종료일이 되어 요일 반복 UI가 사라지고, 저장 시 고른
                                // 요일이 전체 요일로 덮여 월·수·금 반복이 조용히 하루짜리가 된다.
                                if (!on) {
                                    var floor = maxOf(startDayVal, todayStart())
                                    if (weeklyRepeat && floor == startDayVal) {
                                        floor = com.singlemarks.angrymoti.models.ScheduleConflict
                                            .addDays(floor, 6)
                                    }
                                    if ((oneOffEndDay ?: Long.MIN_VALUE) < floor) oneOffEndDay = floor
                                }
                            },
                            colors = SwitchDefaults.colors(checkedTrackColor = TL.rec),
                        )
                    }
                    if (!noEndDate) {
                        Spacer(Modifier.height(12.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("종료일", color = TL.paper, fontSize = 16.sp)
                            Spacer(Modifier.weight(1f))
                            Text(dateLabel(endDayVal), color = TL.paper, fontSize = 15.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.background(TL.raised, CircleShape)
                                    .clickable(enabled = !fieldLocked) { showEndDatePicker = true }
                                    .padding(horizontal = 16.dp, vertical = 9.dp))
                        }
                    }

                    Spacer(Modifier.height(10.dp))
                    androidx.compose.material3.HorizontalDivider(color = TL.hairline)
                    Spacer(Modifier.height(10.dp))

                    if (isSingleDay) {
                        Text("하루짜리 활동이라 요일 반복 설정이 필요 없어요.",
                            color = TL.faint, fontSize = 12.sp)
                    } else {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("요일 반복", color = TL.paper, fontSize = 16.sp)
                            if (!weeklyRepeat) {
                                Spacer(Modifier.width(6.dp))
                                Text("(매일)", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                            }
                            Spacer(Modifier.weight(1f))
                            Switch(
                                checked = weeklyRepeat,
                                onCheckedChange = { on ->
                                    if (fieldLocked) return@Switch
                                    weeklyRepeat = on
                                    // 토글을 켜는 건 '매일은 아니다'라는 선언이다 — 켤 때마다
                                    // 선택을 비운다(기본값은 항상 전부 꺼짐). iOS와 동일 정책.
                                    if (on) repeatDays = emptySet()
                                },
                                colors = SwitchDefaults.colors(checkedTrackColor = TL.jade),
                            )
                        }
                        // 요일 반복 ON → 요일 원형 선택 (최대 6개 — 7개를 모두 고르면 '매일'로 전환)
                        if (weeklyRepeat) {
                            Spacer(Modifier.height(12.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf(1 to "일", 2 to "월", 3 to "화", 4 to "수", 5 to "목", 6 to "금", 7 to "토")
                                    .forEach { (d, label) ->
                                        val on = d in repeatDays
                                        Box(
                                            modifier = Modifier.size(38.dp)
                                                .background(if (on) TL.paper else TL.raised, CircleShape)
                                                // 미선택 요일에도 헤어라인 테두리로 영역 표시
                                                .border(1.dp,
                                                    if (on) androidx.compose.ui.graphics.Color.Transparent else TL.hairline,
                                                    CircleShape)
                                                .clickable {
                                                    if (fieldLocked) return@clickable
                                                    if (on) {
                                                        repeatDays = repeatDays - d
                                                    } else {
                                                        val next = repeatDays + d
                                                        // 7개 전부 = '매일'과 같은 뜻 — 마지막 요일을
                                                        // 채우는 순간 토글을 끄고 매일로 넘긴다.
                                                        if (next.size == 7) {
                                                            weeklyRepeat = false
                                                            repeatDays = emptySet()
                                                        } else {
                                                            repeatDays = next
                                                        }
                                                    }
                                                },
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(label, color = if (on) TL.ink else TL.muted,
                                                fontSize = 14.sp, fontWeight = FontWeight.Bold)
                                        }
                                    }
                            }
                        }
                    }
                }
            }

            // 은퇴한 예약은 삭제 버튼도 없다 — 이미 삭제(종료)된 것을 또 삭제할 수 없다
            existing?.takeIf { !isRetired }?.let { r ->
                Text("예약 삭제", color = TL.rec, fontSize = 17.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.surface, TL.cornerL)
                        .clickable(enabled = !isLocked) {
                            scope.launch(Dispatchers.IO) {
                                AlarmScheduler.cancel(context, r.id)
                                // 오늘 발생이 이미 '진행된' 예약은 통째로 지우지 않고 오늘로
                                // 은퇴시킨다(endAt = 오늘). 진행됨 = 오늘 기록 확정 또는 시작 창
                                // 마감(노쇼 확정 예정). 통째로 지우면 기록탭엔 벌점이 있는데
                                // 일정 탭 오늘 칸이 텅 비어 모순돼 보인다. 은퇴하면 시작 안 한
                                // 미래분만 소멸하고 오늘 행은 자정까지 남으며, isActive가 유지돼
                                // 노쇼 스위퍼도 계속 집계한다 (iOS 1:1).
                                val today = todayStart()
                                val fire = r.occurrenceOn(today)
                                val progressedToday = fire != null && (
                                    fire + TimePolicy.START_WINDOW_SECONDS * 1000 < System.currentTimeMillis() ||
                                    db.sessions().all(r.ownerUserID).any { s ->
                                        s.reservationID == r.id && s.outcome != null &&
                                            (s.scheduledAt ?: 0L) in today until (today + 86_400_000L)
                                    })
                                // 소프트 처리 — 하드 삭제하면 클라우드 사본이 다음 동기화에서
                                // 예약을 되살린다. iOS와 동일하게 비활성/은퇴로 처리하고 전파.
                                val deleted = if (progressedToday)
                                    r.copy(endAt = today, updatedAt = System.currentTimeMillis())
                                else
                                    r.copy(isActive = false, updatedAt = System.currentTimeMillis())
                                db.reservations().upsert(deleted)
                                AccountStore.mirrorReservation(deleted)
                                withContext(Dispatchers.Main) { onDone() }
                            }
                        }.padding(16.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showSlotSheet) {
        ModalBottomSheet(onDismissRequest = { showSlotSheet = false }, containerColor = TL.surface) {
            SlotPolicySheet(streak = streak, isPro = isPro)
        }
    }

    // 일회성 날짜 선택 다이얼로그
    if (showDatePicker) {
        // 오늘(로컬) 이전 날짜는 선택 불가 — 과거 일회성 예약을 애초에 못 만들게 (iOS in: Date()... 통일).
        // DatePicker는 UTC 기준이므로 로컬 오늘의 Y/M/D를 UTC 자정으로 환산해 하한으로 쓴다.
        val todayUtcMidnight = remember { localMidnightToUtc(todayStart()) }
        // 시작일 상한 — 오늘부터 1개월. 무제한이면 알람 안전망의 탐색 범위를 정할 수 없다 (iOS와 동일).
        val maxStartUtcMidnight = remember {
            localMidnightToUtc(com.singlemarks.angrymoti.models.ReservationPolicy.maxStartDayMillis())
        }
        val dateState = androidx.compose.material3.rememberDatePickerState(
            // DatePicker는 UTC 자정 기준이라, 로컬 자정을 그대로 넘기면 KST(UTC+9)에서
            // 전날로 표시되고 그대로 확인하면 시작일이 하루씩 뒤로 밀린다. 반드시 환산해서 넘긴다.
            initialSelectedDateMillis = localMidnightToUtc(
                oneOffDay ?: nextOneOffDay(timeState.hour * 60 + timeState.minute)),
            selectableDates = object : androidx.compose.material3.SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean =
                    utcTimeMillis in todayUtcMidnight..maxStartUtcMidnight
            })
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    // DatePicker는 UTC 자정 기준 — 로컬 자정으로 변환해 저장
                    dateState.selectedDateMillis?.let { picked ->
                        val newStart = utcMidnightToLocal(picked)
                        // 시작일을 뒤로 옮기면 종료일도 함께 밀어준다. 종료일을 시작일에
                        // '붙이지' 말고 기간 길이를 유지한 채 통째로 민다 — 붙이면
                        // 시작일=종료일이 되어 요일 반복 UI가 사라지고, 저장 시 고른 요일이
                        // 전체 요일로 덮여 월·수·금 반복이 조용히 하루짜리가 된다.
                        val oldStart = oneOffDay ?: newStart
                        val end = oneOffEndDay
                        if (end != null && end < newStart) {
                            val spanDays = ((startOfDayLocal(end) - startOfDayLocal(oldStart) +
                                43_200_000L) / 86_400_000L).toInt().coerceAtLeast(0)
                            oneOffEndDay = com.singlemarks.angrymoti.models.ScheduleConflict
                                .addDays(newStart, spanDays)
                        }
                        oneOffDay = newStart
                    }
                    showDatePicker = false
                }) { Text("확인", color = TL.rec, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { showDatePicker = false }) {
                    Text("취소", color = TL.muted)
                }
            },
        ) { androidx.compose.material3.DatePicker(state = dateState) }
    }

    // 종료일 선택 다이얼로그 — 하한은 '시작일과 오늘 중 늦은 쪽' (이미 지난 종료일은 못 고르게)
    if (showEndDatePicker) {
        val startLocalMidnight = oneOffDay ?: nextOneOffDay(timeState.hour * 60 + timeState.minute)
        val floorLocalMidnight = maxOf(startLocalMidnight, todayStart())
        // 로컬 자정을 UTC 자정으로 환산해 하한으로 사용
        val floorUtcMidnight = remember(floorLocalMidnight) { localMidnightToUtc(floorLocalMidnight) }
        val endState = androidx.compose.material3.rememberDatePickerState(
            initialSelectedDateMillis = localMidnightToUtc(
                maxOf(oneOffEndDay ?: floorLocalMidnight, floorLocalMidnight)),
            selectableDates = object : androidx.compose.material3.SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean = utcTimeMillis >= floorUtcMidnight
            })
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { showEndDatePicker = false },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    endState.selectedDateMillis?.let { oneOffEndDay = utcMidnightToLocal(it) }
                    showEndDatePicker = false
                }) { Text("확인", color = TL.rec, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { showEndDatePicker = false }) {
                    Text("취소", color = TL.muted)
                }
            },
        ) { androidx.compose.material3.DatePicker(state = endState) }
    }
}

/** 로컬 자정 → 같은 Y/M/D의 UTC 자정. Material3 DatePicker가 UTC 기준이라,
 *  로컬 자정을 그대로 넘기면 KST(UTC+9)에서 전날 날짜가 선택돼 보인다. */
private fun localMidnightToUtc(localMillis: Long): Long {
    val local = Calendar.getInstance().apply { timeInMillis = localMillis }
    return Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
    }.timeInMillis
}

/** UTC 자정(DatePicker 결과) → 같은 Y/M/D의 로컬 자정 */
private fun utcMidnightToLocal(utcMillis: Long): Long {
    val u = Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply { timeInMillis = utcMillis }
    return Calendar.getInstance().apply {
        set(u.get(Calendar.YEAR), u.get(Calendar.MONTH), u.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}

/** epoch millis → 그 날 로컬 자정 */
private fun startOfDayLocal(millis: Long): Long = Calendar.getInstance().apply {
    timeInMillis = millis
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
    set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

/** 잠긴 예약이 강제로 써야 할 시작일(그 날 자정). 잠기지 않았으면 null.
 *
 *  기준은 createdAt이 아니라 '실제 발생이 시작되는 날'이다. 레거시 일회성 예약은
 *  createdAt이 '만든 시각'이라 실제 날짜(oneOffDayStart)보다 훨씬 이르고, createdAt으로
 *  판정하면 미래 날짜의 일회성 예약도 이미 시작한 것으로 잠겨 버린다. 그 상태로 저장하면
 *  시작일이 만든 날로 끌려가 '만든 날부터 그 날까지 매일'로 바뀌는 손상이 난다.
 *  시작 게이트 당일에 시각만 더해도 안 된다 — 그날이 고른 요일이 아닐 수 있다.
 *  (7/20 월요일부터 '토요일마다'면 첫 발생은 7/25이지 7/20이 아니다)
 *  요일은 7개뿐이라 8일이면 실제 첫 발생을 반드시 찾는다. */
private fun lockedStartDay(r: Reservation): Long? {
    val startDay = r.activeDayRange().first
    var firstFire: Long? = null
    for (offset in 0 until 8) {
        val day = com.singlemarks.angrymoti.models.ScheduleConflict.addDays(startDay, offset)
        val fire = r.occurrenceOn(day) ?: continue
        firstFire = fire
        break
    }
    val fire = firstFire ?: return null
    return if (fire <= System.currentTimeMillis()) startDay else null
}

/** 큰 서피스 입력 필드 — iOS 텍스트필드 1:1.
 *  기본은 포커스일 때만 테두리(하이라인)가 보인다 — '굳이 채우지 않아도 되는 칸'으로
 *  읽히게 한다. unfocusedBorderColor를 넘기면 평소에도 테두리를 보일 수 있다
 *  (활동명처럼 늘 테두리가 있어야 하는 필수 필드, 또는 값이 있을 때만 보이게 하는
 *  직접 입력 태그 필드 등 — 호출부가 조건을 계산해서 넘긴다). */
@Composable
private fun TLField(
    value: String, onChange: (String) -> Unit, placeholder: String, enabled: Boolean = true,
    unfocusedBorderColor: Color = Color.Transparent,
) {
    OutlinedTextField(
        value, onChange, modifier = Modifier.fillMaxWidth(), singleLine = true, enabled = enabled,
        placeholder = { Text(placeholder, color = TL.faint, fontSize = 16.sp) },
        shape = TL.cornerM,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = TL.surface, unfocusedContainerColor = TL.surface,
            disabledContainerColor = TL.surface,
            focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
            focusedBorderColor = TL.hairline.copy(alpha = 0.6f), unfocusedBorderColor = unfocusedBorderColor,
            disabledBorderColor = Color.Transparent,
            cursorColor = TL.rec),
    )
}

private fun dateLabel(dayStart: Long): String {
    val c = Calendar.getInstance().apply { timeInMillis = dayStart }
    return "${c.get(Calendar.YEAR)}. ${c.get(Calendar.MONTH) + 1}. ${c.get(Calendar.DAY_OF_MONTH)}."
}

private fun todayStart(): Long = Calendar.getInstance().apply {
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
    set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

/** 일회성: 오늘 그 시각이 아직 안 지났으면 오늘, 지났으면 내일 */
private fun nextOneOffDay(startMinute: Int): Long {
    val today = todayStart()
    return if (today + startMinute * 60_000L > System.currentTimeMillis()) today
    else today + 86_400_000L
}

/** 활동 슬롯 현황 배지 — 활동 예약·그룹 생성·그룹 참여 공용. 그룹도 슬롯 1개를 차지함을 알린다. */
@Composable
fun SlotStatusBadge(used: Int, allowed: Int?, streak: Int, onClick: () -> Unit) {
    val full = allowed != null && used >= allowed
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background((if (full) TL.amber else TL.jade).copy(alpha = 0.10f), TL.cornerM)
            .clickable(onClick = onClick).padding(12.dp),
    ) {
        Text(if (full) "🔒" else "🔥", fontSize = 14.sp)
        Spacer(Modifier.width(10.dp))
        Column {
            Text("활동 슬롯 $used/${allowed?.toString() ?: "무제한"} · 연속 달성 ${streak}일",
                color = TL.paper, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            Text("그룹도 슬롯 1개를 사용해요 · 터치하면 정책", color = TL.faint, fontSize = 11.sp)
        }
        Spacer(Modifier.weight(1f))
        Text("ⓘ", color = TL.muted, fontSize = 15.sp)
    }
}

@Composable
fun SlotPolicySheet(streak: Int, isPro: Boolean) {
    Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 36.dp)) {
        Text("활동 슬롯 정책", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(6.dp))
        Text("한 가지에 집중하는 습관을 위해 활동 슬롯은 제한됩니다.\n연속 달성일이 늘어날수록 활동 슬롯도 함께 늘어납니다.",
            color = TL.muted, fontSize = 14.sp)
        Spacer(Modifier.height(16.dp))

        // 멤버십 계정은 연속과 무관하게 기본 10개가 보장되므로 사다리를 접고 '기본 10개 / 연속 30일 무제한' 2줄만.
        val rows = if (isPro)
            listOf("기본" to "${SlotPolicy.MEMBER_FLOOR_SLOTS}개", "연속 30일" to "무제한")
        else
            listOf("기본" to "${SlotPolicy.BASE_SLOTS}개") + SlotPolicy.tiers.map { (d, s) ->
                "연속 ${d}일" to (s?.let { "${it}개" } ?: "무제한")
            }
        val currentLabel = when {
            streak >= 30 -> "연속 30일"
            isPro -> "기본"   // 멤버는 30일 미만이면 항상 기본(10개) 행이 현재
            else -> SlotPolicy.tiers.lastOrNull { it.first <= streak }?.let { "연속 ${it.first}일" } ?: "기본"
        }
        rows.forEach { (label, slots) ->
            val isCurrent = label == currentLabel
            Row(
                Modifier.fillMaxWidth()
                    .background(if (isCurrent) TL.jade.copy(alpha = 0.12f) else TL.ink, TL.cornerS)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, color = TL.paper, fontSize = 14.sp,
                    fontWeight = if (isCurrent) FontWeight.Black else FontWeight.Normal)
                if (isCurrent) {
                    Spacer(Modifier.width(8.dp))
                    Text("현재", color = TL.jade, fontSize = 11.sp, fontWeight = FontWeight.Black)
                }
                Spacer(Modifier.weight(1f))
                Text(slots, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(4.dp))
        }
        Spacer(Modifier.height(10.dp))
        Text("👑 멤버십은 연속일과 무관하게 최소 ${SlotPolicy.MEMBER_FLOOR_SLOTS}개부터 시작해요." +
            if (isPro) " (적용 중)" else "",
            color = TL.jade, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text("🛡 연속이 끊기면 한도가 내려가지만, 이미 만든 활동은 사라지지 않아요. 새로 추가하는 것만 제한됩니다.",
            color = TL.muted, fontSize = 12.sp)
    }
}

@Composable
fun WeeklyScheduleTab(
    reservations: List<Reservation>,
    onAdd: () -> Unit,
    onEdit: (Reservation) -> Unit,
    onOpenGroup: (String) -> Unit = {},
) {
    // 60초 틱 — 컴포지션 1회 계산으로 두면 탭을 열어둔 채 시작 창이 지나가도 행 흐림이
    // 안 바뀌고, 자정이 지나도 요일 정렬·오늘 배지가 그대로다 (iOS 60초 타이머 1:1)
    var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            kotlinx.coroutines.delay(60_000)
            nowMillis = System.currentTimeMillis()
        }
    }
    val todayDow = Calendar.getInstance().apply { timeInMillis = nowMillis }.get(Calendar.DAY_OF_WEEK)
    // 오늘 요일을 맨 위에 두고 순환 정렬 (1=일 … 7=토). 예) 오늘 토→토·일·월·화·수·목·금.
    val dayNames = mapOf(1 to "일요일", 2 to "월요일", 3 to "화요일", 4 to "수요일",
        5 to "목요일", 6 to "금요일", 7 to "토요일")
    val weekdays = (0..6).map { val dow = ((todayDow - 1 + it) % 7) + 1; dow to dayNames.getValue(dow) }

    // 오늘 확정 결과 — 예약별로 '한 번만' 표를 만든다 (행마다 전체 스캔 금지, iOS 동일 규칙).
    // 하루에 기록이 여럿(긴급 중단 후 재촬영)이면 가장 나중 것을 남긴다.
    val ctx = LocalContext.current
    val owner = AccountStore.currentUserID
    val allSessions by AppDb.get(ctx).sessions().allFlow(owner)
        .collectAsState(initial = emptyList())
    val todayStartMillis = Calendar.getInstance().apply {
        timeInMillis = nowMillis
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis
    val todayOutcomes: Map<String, com.singlemarks.angrymoti.models.SessionOutcome> =
        remember(allSessions, todayStartMillis) {
            val map = mutableMapOf<String, Pair<Long, com.singlemarks.angrymoti.models.SessionOutcome>>()
            for (sess in allSessions) {
                val rid = sess.reservationID ?: continue
                val outcome = sess.outcome ?: continue
                val sched = sess.scheduledAt ?: continue
                if (sched < todayStartMillis || sched >= todayStartMillis + 86_400_000L) continue
                val at = sess.endedAt ?: sess.startedAt ?: 0L
                val prev = map[rid]
                if (prev == null || at > prev.first) map[rid] = at to outcome
            }
            map.mapValues { it.value.second }
        }

    // 그 날 실제로 알람이 울리는 예약만 — 알람시계 로직(occurrenceOn) 한 곳으로 판정한다.
    // 요일/일회성 매칭 + 시작일(createdAt) 전·종료일(endAt) 후 자동 제외까지 함께 처리된다.
    // 그룹 예약도 (참여자 미달로 폭파될 수 있어도) 활동 기간 안이면 일정에 넣어 계획을 관리하게 한다 —
    // 실제 폭파되면 GroupStore가 예약을 DB에서 제거한다.
    fun itemsOn(dayStart: Long): List<Reservation> =
        reservations.filter { it.occurrenceOn(dayStart) != null }.sortedBy { it.startMinute }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // 상단 — 중앙 '주간 일정' 타이틀 + 우측 '+추가' (iOS 네비게이션 바 인라인 타이틀 1:1)
        item {
            Box(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                Text("주간 일정", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.align(Alignment.Center))
                Row(verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.align(Alignment.CenterEnd)
                        .clip(CircleShape)
                        .clickable(onClick = onAdd)
                        .padding(horizontal = 10.dp, vertical = 6.dp)) {
                    Text("+ 추가", color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }

        weekdays.forEachIndexed { offset, (dow, label) ->
            // 오늘부터 offset일 뒤 날짜 (요일 순환 순서와 1:1)
            val dayCal = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_YEAR, offset)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            val dayStart = dayCal.timeInMillis
            val md = "${dayCal.get(Calendar.MONTH) + 1}월 ${dayCal.get(Calendar.DAY_OF_MONTH)}일"
            val dayItems = itemsOn(dayStart)
            val isToday = dow == todayDow
            item(key = "day-$dow") {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    // 요일 헤더 + 실제 날짜 병기 + '오늘' 빨강 캡슐. 예) "토요일 (7월 25일)"
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(label, color = if (isToday) TL.rec else TL.paper,
                            fontSize = 16.sp, fontWeight = FontWeight.Black)
                        Spacer(Modifier.width(6.dp))
                        Text("($md)", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        if (isToday) {
                            Spacer(Modifier.width(8.dp))
                            Text("오늘", color = TL.ink, fontSize = 11.sp, fontWeight = FontWeight.Black,
                                modifier = Modifier.background(TL.rec, CircleShape)
                                    .padding(horizontal = 8.dp, vertical = 3.dp))
                        }
                    }
                    if (dayItems.isEmpty()) {
                        Text("일정 없음", color = TL.faint, fontSize = 12.sp,
                            modifier = Modifier.padding(start = 2.dp, top = 2.dp, bottom = 2.dp))
                    } else {
                        // 그 날 예약들을 하나의 카드로 묶고, 오늘이면 빨강 테두리 강조 (iOS 1:1)
                        Column(
                            Modifier.fillMaxWidth()
                                .background(if (isToday) TL.raised else TL.surface, TL.cornerL)
                                .border(1.dp,
                                    if (isToday) TL.rec.copy(alpha = 0.35f) else TL.hairline.copy(alpha = 0.6f),
                                    TL.cornerL)
                                .padding(horizontal = 14.dp),
                        ) {
                            dayItems.forEachIndexed { index, r ->
                                // 오늘만 상태를 계산한다 — 다른 날짜는 항상 예정(밝게, 표시등 없음)
                                val fire = if (isToday) r.occurrenceOn(dayStart) else null
                                val outcome = if (isToday) todayOutcomes[r.id] else null
                                val missed = isToday && outcome == null && fire != null &&
                                    nowMillis > fire + TimePolicy.START_WINDOW_SECONDS * 1000
                                // 표시등: 성공=초록, 그 외 전부 빨강. 두 색뿐 — 안전 종료(무효)도
                                // 빨강이다. 무효는 벌점화만 안 되는 것이지 완주 실패는 같다 (iOS 1:1).
                                val light: Color? = outcome?.let { if (it.isSuccess) TL.jade else TL.rec }
                                ScheduleRow(r,
                                    dimmed = outcome != null || missed,
                                    light = light,
                                    onClick = {
                                        if (r.groupId != null) onOpenGroup(r.groupId!!) else onEdit(r)
                                    })
                                if (index != dayItems.lastIndex) {
                                    androidx.compose.material3.HorizontalDivider(
                                        color = TL.hairline.copy(alpha = 0.5f))
                                }
                            }
                        }
                    }
                }
            }
        }
        // '이후 예정' — 오늘~6일 뒤 어디에도 발생이 없는 활동 (iOS laterSection 1:1).
        // 주간 표에 없다고 활동 자체가 사라진 게 아님을 보여준다.
        item(key = "later") {
            // Calendar 기반 날짜 이동 — 밀리초 산술은 DST가 있는 로케일에서 자정이 어긋나
            // occurrenceOn(자정 키 요구)이 발생을 놓친다. 주간 그리드와 판정 축 통일.
            val horizon = ScheduleConflict.addDays(todayStartMillis, 7)
            val laterItems = reservations.mapNotNull { r ->
                val visibleThisWeek = (0..6).any { off ->
                    r.occurrenceOn(ScheduleConflict.addDays(todayStartMillis, off)) != null
                }
                if (visibleThisWeek) return@mapNotNull null
                // -1초: nextOccurrence는 '이후'만 반환하므로 자정 정각 발생이 걸러지지 않게
                val next = r.nextOccurrence(horizon - 1000L) ?: return@mapNotNull null
                r to next
            }.sortedBy { it.second }
            if (laterItems.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("이후 예정", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Black)
                    Column(
                        Modifier.fillMaxWidth().background(TL.surface, TL.cornerL)
                            .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
                            .padding(horizontal = 14.dp),
                    ) {
                        laterItems.forEachIndexed { index, (r, next) ->
                            val c = Calendar.getInstance().apply { timeInMillis = next }
                            val dDays = ((next - todayStartMillis) / 86_400_000L).toInt()
                            Row(verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth()
                                    .clickable {
                                        if (r.groupId != null) onOpenGroup(r.groupId!!) else onEdit(r)
                                    }
                                    .padding(vertical = 11.dp)) {
                                Text("${c.get(Calendar.MONTH) + 1}월 ${c.get(Calendar.DAY_OF_MONTH)}일",
                                    color = TL.paper, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                                    modifier = Modifier.width(78.dp))
                                Column(Modifier.weight(1f).padding(end = 6.dp)) {
                                    // 순서: 제목 → 🔥(미친맛) → 그룹 아이콘 (iOS laterRow 1:1)
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(r.name, color = TL.paper, fontSize = 14.sp,
                                            fontWeight = FontWeight.SemiBold, maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f, fill = false))
                                        if (isInsane(r)) {
                                            Spacer(Modifier.width(4.dp))
                                            Text("🔥", fontSize = 12.sp)
                                        }
                                        if (r.groupId != null) {
                                            Spacer(Modifier.width(4.dp))
                                            androidx.compose.material3.Icon(AppIcon.Users, null,
                                                tint = TL.amber, modifier = Modifier.size(13.dp))
                                        }
                                    }
                                    Text("${TLFormat.timeLabel(r.startMinute)} · ${TLFormat.durationLabel(r.durationMinutes)}",
                                        color = TL.muted, fontSize = 11.sp)
                                }
                                Text("D-$dDays", color = TL.ink, fontSize = 11.sp,
                                    fontWeight = FontWeight.Black,
                                    modifier = Modifier.background(TL.amber, CircleShape)
                                        .padding(horizontal = 8.dp, vertical = 3.dp))
                                Spacer(Modifier.width(6.dp))
                                TagBadge(r.tag)
                            }
                            if (index != laterItems.lastIndex) {
                                androidx.compose.material3.HorizontalDivider(
                                    color = TL.hairline.copy(alpha = 0.5f))
                            }
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(110.dp)) }
    }
}

/** 주간 일정 한 줄 — 시각 · (그룹아이콘)활동명 · 길이/매일·반복요일·하루 · 태그칩 (iOS timetableRow 1:1) */
@Composable
private fun ScheduleRow(
    r: Reservation,
    dimmed: Boolean = false,
    light: Color? = null,
    onClick: () -> Unit,
) {
    // 시작일=종료일이면 요일 반복 여부와 무관하게 그날 하루만 진행하는 활동.
    val sameDay = r.endAt?.let { end ->
        val a = Calendar.getInstance().apply { timeInMillis = r.createdAt }
        val b = Calendar.getInstance().apply { timeInMillis = end }
        a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
    } ?: false
    val meta = when {
        sameDay -> {
            val c = Calendar.getInstance().apply { timeInMillis = r.createdAt }
            "${c.get(Calendar.MONTH) + 1}월 ${c.get(Calendar.DAY_OF_MONTH)}일 하루"
        }
        // 표기는 '매일' / '반복요일' 두 가지로만 — 기간이 짧으면 '매주'가 사실과 달라진다.
        r.repeatWeekdays.size == 7 -> "매일"          // 요일 전체 = 매일(기간)
        r.isRepeating -> "반복요일"
        r.oneOffDayStart != null -> {
            val c = Calendar.getInstance().apply { timeInMillis = r.oneOffDayStart!! }
            "${c.get(Calendar.MONTH) + 1}월 ${c.get(Calendar.DAY_OF_MONTH)}일 하루"
        }
        else -> "매일"
    }
    // 지나간 일정은 통째로 흐리게 — 오늘 남은 일정과 한눈에 구분된다.
    // 결과 표시등만 원래 밝기를 유지해 성공/실패를 바로 읽을 수 있게 한다 (iOS 1:1).
    val contentAlpha = if (dimmed) 0.42f else 1f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically,
            // 태그와의 최소 간격 6dp — 제목이 잘릴 때 한 글자라도 더 보이는 쪽을 택했다 (iOS 1:1)
            modifier = Modifier.weight(1f).padding(end = 6.dp)
                .graphicsLayer { alpha = contentAlpha }) {
            Text(TLFormat.timeLabel(r.startMinute), color = TL.paper, fontSize = 14.sp,
                fontWeight = FontWeight.Black, modifier = Modifier.width(78.dp))
            Column(Modifier.weight(1f)) {
                // 순서: 제목 → 🔥(미친맛) → 그룹 아이콘 (iOS 1:1). 제목이 길면 제목만
                // 말줄임되고 아이콘은 밀려나지 않는다 (weight fill=false).
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(r.name, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false))
                    if (isInsane(r)) {
                        Spacer(Modifier.width(4.dp))
                        Text("🔥", fontSize = 12.sp)
                    }
                    if (r.groupId != null) {
                        Spacer(Modifier.width(4.dp))
                        androidx.compose.material3.Icon(AppIcon.Users, null,
                            tint = TL.amber, modifier = Modifier.size(13.dp))
                    }
                }
                Text("${TLFormat.durationLabel(r.durationMinutes)} · $meta",
                    color = TL.muted, fontSize = 11.sp)
            }
        }
        // 결과 표시등 — 8pt 원 + 은은한 후광, 태그 왼쪽 (iOS 1:1)
        if (light != null) {
            Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(14.dp).background(light.copy(alpha = 0.35f), CircleShape))
                Box(Modifier.size(8.dp).background(light, CircleShape))
            }
            Spacer(Modifier.width(6.dp))
        }
        // 태그 칩 — 태그별 고유 색 (iOS TagChip 비선택 규칙과 동일)
        TagBadge(r.tag, alpha = if (dimmed) 0.55f else 1f)
    }
}

/** 미친 매운맛만 표시 — 매운맛(기본값)은 무표기라 목록이 조용하다 (iOS isInsane 1:1). */
private fun isInsane(r: Reservation): Boolean =
    (r.intensityOverride ?: com.singlemarks.angrymoti.AppState.intensity.value) == Intensity.INSANE
