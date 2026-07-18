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
    var startMinute by remember { mutableStateOf(TimePolicy.defaultStartMinute()) }
    var durationMinutes by remember { mutableStateOf(60) }
    var repeatDays by remember { mutableStateOf(setOf<Int>()) }
    var error by remember { mutableStateOf<String?>(null) }
    var showSlotSheet by remember { mutableStateOf(false) }
    var allSessions by remember { mutableStateOf(listOf<com.singlemarks.angrymoti.data.FocusSession>()) }
    var allReservations by remember { mutableStateOf(listOf<Reservation>()) }

    LaunchedEffect(reservationId) {
        withContext(Dispatchers.IO) {
            allSessions = db.sessions().all(owner)
            allReservations = db.reservations().active(owner)
            reservationId?.let { id ->
                db.reservations().byId(id)?.let { r ->
                    existing = r
                    name = r.name; tag = r.tag; startMinute = r.startMinute
                    durationMinutes = r.durationMinutes; repeatDays = r.repeatWeekdays.toSet()
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

    val timeState = rememberTimePickerState(
        initialHour = startMinute / 60, initialMinute = startMinute % 60, is24Hour = false)

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("취소", color = TL.muted, fontSize = 16.sp,
                modifier = Modifier.clickable(onClick = onDone).padding(4.dp))
            Spacer(Modifier.weight(1f))
            Text(if (existing == null) "활동 추가" else "활동 편집",
                color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            Text("저장", color = if (isLocked) TL.faint else TL.rec, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.clickable(enabled = !isLocked) {
                    // 검증 — 오류는 최상단에 즉시 표시
                    val finalName = name.trim()
                    val sm = timeState.hour * 60 + timeState.minute
                    if (finalName.isEmpty()) { error = "활동명을 입력해주세요."; return@clickable }
                    if (slotFull) { error = "활동 슬롯이 가득 찼어요. 연속 달성일을 쌓으면 슬롯이 늘어나요."; return@clickable }
                    val overlap = allReservations.any { other ->
                        other.id != existing?.id && other.overlaps(sm, durationMinutes) &&
                            (other.isRepeating || repeatDays.isNotEmpty() ||
                                other.oneOffDayStart == todayStart())
                    }
                    if (overlap) { error = "같은 시간대에 이미 다른 활동이 있어요."; return@clickable }

                    scope.launch(Dispatchers.IO) {
                        val r = (existing ?: Reservation(
                            ownerUserID = owner, name = finalName, tag = tag,
                            startMinute = sm, durationMinutes = durationMinutes,
                        )).copy(
                            name = finalName, tag = tag, startMinute = sm,
                            durationMinutes = durationMinutes,
                            repeatWeekdaysCsv = repeatDays.sorted().joinToString(","),
                            oneOffDayStart = if (repeatDays.isEmpty()) nextOneOffDay(sm) else null,
                        )
                        db.reservations().upsert(r)
                        r.nextOccurrence()?.let { AlarmScheduler.scheduleExact(context, r.id, it) }
                        withContext(Dispatchers.Main) { onDone() }
                    }
                }.padding(4.dp))
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

            Column {
                TLEyebrow("활동명")
                OutlinedTextField(
                    name, { name = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                    enabled = !isLocked,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                        focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline, cursorColor = TL.rec),
                )
            }

            Column {
                TLEyebrow("태그")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(ActivityTag.presets.size) { i ->
                        val p = ActivityTag.presets[i]
                        TagChip(p, tag == p) { if (!isLocked) tag = p }
                    }
                }
            }

            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TLEyebrow("시작 시각 · 활동 시간")
                    Spacer(Modifier.weight(1f))
                    Text("완료 시 +${ScoreRules.completionBase(durationMinutes)}점",
                        color = TL.jade, fontSize = 12.sp, fontWeight = FontWeight.Black,
                        modifier = Modifier.background(TL.jade.copy(alpha = 0.14f), CircleShape)
                            .padding(horizontal = 10.dp, vertical = 5.dp))
                }
                TLCard {
                    TimePicker(state = timeState)
                    Spacer(Modifier.height(8.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(TimePolicy.durationOptionsMinutes.size) { i ->
                            val m = TimePolicy.durationOptionsMinutes[i]
                            TagChip(TLFormat.durationLabel(m), durationMinutes == m) {
                                if (!isLocked) durationMinutes = m
                            }
                        }
                    }
                }
            }

            Column {
                TLEyebrow("반복")
                TLCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("요일 반복", color = TL.paper, fontSize = 15.sp)
                        Spacer(Modifier.weight(1f))
                        Switch(
                            checked = repeatDays.isNotEmpty(),
                            onCheckedChange = { on ->
                                if (isLocked) return@Switch
                                repeatDays = if (on) setOf(2, 3, 4, 5, 6) else emptySet()
                            },
                            colors = SwitchDefaults.colors(checkedTrackColor = TL.rec),
                        )
                    }
                    if (repeatDays.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            listOf(1 to "일", 2 to "월", 3 to "화", 4 to "수", 5 to "목", 6 to "금", 7 to "토")
                                .forEach { (d, label) ->
                                    Box(
                                        modifier = Modifier
                                            .background(if (d in repeatDays) TL.rec else TL.raised, CircleShape)
                                            .clickable {
                                                if (isLocked) return@clickable
                                                repeatDays = if (d in repeatDays) repeatDays - d else repeatDays + d
                                            }.padding(horizontal = 12.dp, vertical = 8.dp),
                                    ) {
                                        Text(label, color = if (d in repeatDays) TL.paper else TL.muted,
                                            fontSize = 13.sp, fontWeight = FontWeight.Bold)
                                    }
                                }
                        }
                    } else {
                        Text("반복 없이 다음 도래하는 시각 1회만 울려요", color = TL.faint, fontSize = 12.sp,
                            modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }

            existing?.let { r ->
                Text("활동 삭제", color = TL.rec, fontSize = 15.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.fillMaxWidth()
                        .background(TL.raised, TL.cornerM)
                        .clickable(enabled = !isLocked) {
                            scope.launch(Dispatchers.IO) {
                                AlarmScheduler.cancel(context, r.id)
                                db.reservations().delete(r)
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

        val rows = listOf("기본" to "2개") + SlotPolicy.tiers.map { (d, s) ->
            "연속 ${d}일" to (s?.let { "${it}개" } ?: "무제한")
        }
        val currentLabel = when {
            streak >= 30 -> "연속 30일"
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
) {
    val todayDow = Calendar.getInstance().get(Calendar.DAY_OF_WEEK)
    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TLEyebrow("주간 타임테이블")
                Spacer(Modifier.weight(1f))
                Text("+ 추가", color = TL.rec, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.clickable(onClick = onAdd).padding(4.dp))
            }
        }
        listOf(2 to "월", 3 to "화", 4 to "수", 5 to "목", 6 to "금", 7 to "토", 1 to "일").forEach { (dow, label) ->
            val dayItems = reservations
                .filter { it.isRepeating && dow in it.repeatWeekdays }
                .sortedBy { it.startMinute }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(label, color = if (dow == todayDow) TL.rec else TL.muted,
                        fontSize = 15.sp, fontWeight = FontWeight.Black)
                    if (dow == todayDow) {
                        Spacer(Modifier.width(6.dp))
                        Text("오늘", color = TL.rec, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            if (dayItems.isEmpty()) {
                item { Text("—", color = TL.faint, fontSize = 13.sp, modifier = Modifier.padding(start = 4.dp)) }
            } else {
                dayItems.forEach { r ->
                    item {
                        TLCard(onClick = { onEdit(r) }) {
                            Row {
                                Text(TLFormat.timeLabel(r.startMinute), color = TL.amber,
                                    fontSize = 13.sp, fontWeight = FontWeight.Bold)
                                Spacer(Modifier.width(10.dp))
                                Text(r.name, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                                Spacer(Modifier.weight(1f))
                                Text(TLFormat.durationLabel(r.durationMinutes), color = TL.muted, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(16.dp)) }
    }
}
