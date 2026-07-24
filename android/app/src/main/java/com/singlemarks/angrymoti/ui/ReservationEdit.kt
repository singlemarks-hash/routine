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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.models.ActivityTag
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

    var loaded by remember { mutableStateOf(reservationId == null) }
    var existing by remember { mutableStateOf<Reservation?>(null) }
    var name by remember { mutableStateOf("") }
    var tag by remember { mutableStateOf(ActivityTag.presets.first()) }
    var customTag by remember { mutableStateOf("") }
    var startMinute by remember { mutableStateOf(TimePolicy.defaultStartMinute()) }
    var durationMinutes by remember { mutableStateOf(60) }
    var repeatDays by remember { mutableStateOf(setOf<Int>()) }
    var oneOffDay by remember { mutableStateOf<Long?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var showSlotSheet by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }
    var showDurationMenu by remember { mutableStateOf(false) }
    var showDatePicker by remember { mutableStateOf(false) }
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
                    durationMinutes = r.durationMinutes; repeatDays = r.repeatWeekdays.toSet()
                    oneOffDay = r.oneOffDayStart
                    if (r.tag in ActivityTag.presets) tag = r.tag else customTag = r.tag
                }
            }
            loaded = true
        }
    }
    if (!loaded) return

    val streak = SlotPolicy.currentStreak(
        allSessions.filter { it.outcome != null }
            .map { Triple(it.anchorAt, it.outcome!!.isSuccess, it.outcome!!.isFailure) }
    )
    val allowed = SlotPolicy.allowedSlots(streak, isPro)
    val used = allReservations.size
    val slotFull = allowed != null && used >= allowed && existing == null

    /** 시작 30분 전 편집 잠금 */
    val isLocked = existing?.nextOccurrence()?.let { it - System.currentTimeMillis() <= 30 * 60_000L } == true

    /** 슬롯 초과(강등·연속 하락) — 보유 예약이 허용치를 넘으면 편집 잠그고 삭제만 허용(읽기 전용) */
    val overSlotLimit = allowed != null && used > allowed
    val editReadOnly = existing != null && overSlotLimit
    /** 입력 필드·저장 잠금 = 시작 임박 ∨ 슬롯 초과 읽기 전용 (삭제는 예외로 isLocked만 적용) */
    val fieldLocked = isLocked || editReadOnly

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
            TLPillButton("저장", tint = TL.rec, enabled = !fieldLocked, onClick = save@{
                    // 검증 — 오류는 최상단에 즉시 표시
                    val finalName = name.trim()
                    val finalTag = customTag.trim().ifEmpty { tag }
                    val sm = timeState.hour * 60 + timeState.minute
                    // 슬롯 초과 읽기 전용 — 편집 저장 차단(삭제만 허용). 버튼도 비활성이지만 백스톱.
                    if (editReadOnly) { error = "슬롯 한도를 초과해 편집이 잠겼어요. 예약을 삭제해 슬롯 수 이내로 정리하면 다시 편집할 수 있어요."; return@save }
                    if (finalName.isEmpty()) { error = "활동명을 입력해주세요."; return@save }
                    if (slotFull) { error = "활동 슬롯이 가득 찼어요. 연속 달성일을 쌓으면 슬롯이 늘어나요."; return@save }
                    val overlap = allReservations.any { other ->
                        other.id != existing?.id && other.overlaps(sm, durationMinutes) &&
                            (other.isRepeating || repeatDays.isNotEmpty() ||
                                other.oneOffDayStart == todayStart())
                    }
                    if (overlap) { error = "같은 시간대에 이미 다른 활동이 있어요."; return@save }
                    // 일회성 예약은 발생 시각이 미래여야 한다 — 과거면 알람이 아예 안 걸리므로 차단 (iOS 통일)
                    if (repeatDays.isEmpty()) {
                        val oneOffStart = oneOffDay ?: nextOneOffDay(sm)
                        if (oneOffStart + sm * 60_000L <= System.currentTimeMillis()) {
                            error = "이미 지난 시각입니다. 미래 날짜·시각으로 선택해주세요."; return@save
                        }
                    }

                    scope.launch(Dispatchers.IO) {
                        val r = (existing ?: Reservation(
                            ownerUserID = owner, name = finalName, tag = finalTag,
                            startMinute = sm, durationMinutes = durationMinutes,
                        )).copy(
                            name = finalName, tag = finalTag, startMinute = sm,
                            durationMinutes = durationMinutes,
                            repeatWeekdaysCsv = repeatDays.sorted().joinToString(","),
                            oneOffDayStart = if (repeatDays.isEmpty()) (oneOffDay ?: nextOneOffDay(sm)) else null,
                            // 편집 시 책임 기준 시각 갱신 — 더 이른 시각으로 옮겨도
                            // '오늘 이미 지나간 새 시각' 발생분이 소급 노쇼되지 않게.
                            // (createdAt은 복구 로직의 기준이므로 건드리지 않는다)
                            accountableFrom = if (existing != null) System.currentTimeMillis() else null,
                            updatedAt = System.currentTimeMillis(),
                        )
                        db.reservations().upsert(r)
                        AccountStore.mirrorReservation(r)   // 크로스 기기 동기화
                        r.nextOccurrence()?.let { AlarmScheduler.scheduleExact(context, r.id, it) }
                        withContext(Dispatchers.Main) { onDone() }
                    }
                })
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
            if (isLocked) {
                Text("시작 30분 전에는 편집할 수 없어요", color = TL.amber, fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.amber.copy(alpha = 0.12f), TL.cornerM).padding(12.dp))
            }
            if (editReadOnly) {
                Text("활동 슬롯이 ${allowed}개로 줄어 보유한 예약이 한도를 넘었어요. 초과한 동안에는 편집이 잠기고 삭제만 할 수 있어요. 예약을 슬롯 수 이내로 정리하거나 멤버십·연속 달성으로 슬롯을 늘리면 다시 편집할 수 있어요.",
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

            // ── 활동명 (필수) — 큰 서피스 입력 필드 (iOS 1:1)
            Column {
                TLEyebrow("활동명 (필수)")
                TLField(name, { name = it }, "예: 기출문제 3회분", enabled = !fieldLocked)
            }

            // ── 태그 — 프리셋 칩 + '직접 입력' 필드 (iOS 1:1)
            Column {
                TLEyebrow("태그")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(ActivityTag.presets.size) { i ->
                        val p = ActivityTag.presets[i]
                        TagChip(p, customTag.isBlank() && tag == p) {
                            if (!fieldLocked) { tag = p; customTag = "" }
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                TLField(customTag, { customTag = it }, "직접 입력", enabled = !fieldLocked)
            }

            // ── 시작 시각 · 활동 시간 — 한 카드: 값 필 행 + 길이 드롭다운 + 점수 태그 (iOS 1:1)
            Column {
                TLEyebrow("시작 시각 · 활동 시간")
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
                                modifier = Modifier
                                    .clickable(enabled = !fieldLocked) { showDurationMenu = true }
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
                                        onClick = { durationMinutes = m; showDurationMenu = false },
                                    )
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

            // ── 반복 — 요일 반복 토글 + (꺼짐: 날짜 필 / 켜짐: 요일 원형) (iOS 1:1)
            Column {
                TLEyebrow("반복")
                TLCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("요일 반복", color = TL.paper, fontSize = 16.sp)
                        Spacer(Modifier.weight(1f))
                        Switch(
                            checked = repeatDays.isNotEmpty(),
                            onCheckedChange = { on ->
                                if (fieldLocked) return@Switch
                                repeatDays = if (on) setOf(2, 3, 4, 5, 6) else emptySet()
                            },
                            colors = SwitchDefaults.colors(checkedTrackColor = TL.jade),
                        )
                    }
                    if (repeatDays.isNotEmpty()) {
                        Spacer(Modifier.height(12.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(1 to "일", 2 to "월", 3 to "화", 4 to "수", 5 to "목", 6 to "금", 7 to "토")
                                .forEach { (d, label) ->
                                    val on = d in repeatDays
                                    Box(
                                        modifier = Modifier.size(38.dp)
                                            .background(if (on) TL.paper else TL.raised, CircleShape)
                                            .clickable {
                                                if (fieldLocked) return@clickable
                                                repeatDays = if (on) repeatDays - d else repeatDays + d
                                            },
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Text(label, color = if (on) TL.ink else TL.muted,
                                            fontSize = 14.sp, fontWeight = FontWeight.Bold)
                                    }
                                }
                        }
                    } else {
                        Spacer(Modifier.height(12.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("날짜", color = TL.paper, fontSize = 16.sp)
                            Spacer(Modifier.weight(1f))
                            val day = oneOffDay ?: nextOneOffDay(timeState.hour * 60 + timeState.minute)
                            Text(dateLabel(day), color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                                modifier = Modifier.background(TL.raised, CircleShape)
                                    .clickable(enabled = !fieldLocked) { showDatePicker = true }
                                    .padding(horizontal = 16.dp, vertical = 9.dp))
                        }
                    }
                }
            }

            existing?.let { r ->
                Text("예약 삭제", color = TL.rec, fontSize = 17.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.surface, TL.cornerL)
                        .clickable(enabled = !isLocked) {
                            scope.launch(Dispatchers.IO) {
                                AlarmScheduler.cancel(context, r.id)
                                // 소프트 삭제 — 하드 삭제하면 클라우드 사본이 다음 동기화에서
                                // 예약을 되살린다. iOS와 동일하게 비활성화로 처리하고 전파.
                                val deleted = r.copy(isActive = false,
                                    updatedAt = System.currentTimeMillis())
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
        val todayUtcMidnight = remember {
            val local = Calendar.getInstance()
            Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
                clear()
                set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
            }.timeInMillis
        }
        val dateState = androidx.compose.material3.rememberDatePickerState(
            initialSelectedDateMillis = oneOffDay ?: nextOneOffDay(timeState.hour * 60 + timeState.minute),
            selectableDates = object : androidx.compose.material3.SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean = utcTimeMillis >= todayUtcMidnight
            })
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    dateState.selectedDateMillis?.let { utc ->
                        // DatePicker는 UTC 자정 기준 — 로컬 자정으로 변환해 저장
                        val u = Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
                            .apply { timeInMillis = utc }
                        val local = Calendar.getInstance().apply {
                            set(u.get(Calendar.YEAR), u.get(Calendar.MONTH), u.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
                            set(Calendar.MILLISECOND, 0)
                        }
                        oneOffDay = local.timeInMillis
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
}

/** 큰 서피스 입력 필드 — iOS 텍스트필드 1:1 (배경 서피스, 테두리 없음) */
@Composable
private fun TLField(value: String, onChange: (String) -> Unit, placeholder: String, enabled: Boolean = true) {
    OutlinedTextField(
        value, onChange, modifier = Modifier.fillMaxWidth(), singleLine = true, enabled = enabled,
        placeholder = { Text(placeholder, color = TL.faint, fontSize = 16.sp) },
        shape = TL.cornerM,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = TL.surface, unfocusedContainerColor = TL.surface,
            disabledContainerColor = TL.surface,
            focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
            focusedBorderColor = TL.hairline, unfocusedBorderColor = Color.Transparent,
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

@Composable
fun SlotPolicySheet(streak: Int, isPro: Boolean) {
    Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 36.dp)) {
        Text("활동 슬롯 정책", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(6.dp))
        Text("하나에 집중하는 습관을 위해, 활동 슬롯은 연속 달성일로 늘어납니다.",
            color = TL.muted, fontSize = 14.sp)
        Spacer(Modifier.height(16.dp))

        // 멤버십 계정은 연속과 무관하게 기본 10개가 보장되므로 사다리를 접고 '기본 10개 / 연속 30일 무제한' 2줄만.
        val rows = if (isPro)
            listOf("기본" to "${SlotPolicy.MEMBER_FLOOR_SLOTS}개", "연속 30일" to "무제한")
        else
            listOf("기본" to "2개") + SlotPolicy.tiers.map { (d, s) ->
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
    val todayDow = Calendar.getInstance().get(Calendar.DAY_OF_WEEK)
    val weekdays = listOf(2 to "월요일", 3 to "화요일", 4 to "수요일", 5 to "목요일",
        6 to "금요일", 7 to "토요일", 1 to "일요일")

    fun itemsOn(dow: Int): List<Reservation> = reservations.filter { r ->
        if (r.isRepeating) dow in r.repeatWeekdays
        else r.oneOffDayStart?.let {
            Calendar.getInstance().apply { timeInMillis = it }.get(Calendar.DAY_OF_WEEK) == dow
        } == true
    }.sortedBy { it.startMinute }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // 상단 — '주간 일정' 타이틀 + '+추가' 버튼 (iOS 1:1)
        item {
            Row(verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(top = 6.dp)) {
                Text("주간 일정", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .background(TL.surface, CircleShape)
                        .border(1.dp, TL.hairline, CircleShape)
                        .clickable(onClick = onAdd)
                        .padding(horizontal = 16.dp, vertical = 9.dp)) {
                    Text("+ 추가", color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
            }
        }

        weekdays.forEach { (dow, label) ->
            val dayItems = itemsOn(dow)
            val isToday = dow == todayDow
            item(key = "day-$dow") {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    // 요일 헤더 + '오늘' 빨강 캡슐
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(label, color = if (isToday) TL.rec else TL.paper,
                            fontSize = 16.sp, fontWeight = FontWeight.Black)
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
                                ScheduleRow(r,
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
        item { Spacer(Modifier.height(110.dp)) }
    }
}

/** 주간 일정 한 줄 — 시각 · (그룹아이콘)활동명 · 길이/매주·일회성 · 태그칩 (iOS timetableRow 1:1) */
@Composable
private fun ScheduleRow(r: Reservation, onClick: () -> Unit) {
    val meta = if (r.isRepeating) "매주" else r.oneOffDayStart?.let {
        val c = Calendar.getInstance().apply { timeInMillis = it }
        "${c.get(Calendar.MONTH) + 1}월 ${c.get(Calendar.DAY_OF_MONTH)}일 하루"
    } ?: "매주"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp),
    ) {
        Text(TLFormat.timeLabel(r.startMinute), color = TL.paper, fontSize = 14.sp,
            fontWeight = FontWeight.Black, modifier = Modifier.width(78.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (r.groupId != null) {
                    androidx.compose.material3.Icon(AppIcon.Users, null,
                        tint = TL.amber, modifier = Modifier.size(13.dp))
                    Spacer(Modifier.width(4.dp))
                }
                Text(r.name, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1)
            }
            Text("${TLFormat.durationLabel(r.durationMinutes)} · $meta",
                color = TL.muted, fontSize = 11.sp)
        }
        // 태그 칩
        Text(r.tag, color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.background(TL.surface, CircleShape)
                .border(1.dp, TL.hairline, CircleShape)
                .padding(horizontal = 12.dp, vertical = 6.dp))
    }
}
