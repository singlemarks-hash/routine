package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.Image
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.AppState
import com.singlemarks.angrymoti.PendingSession
import com.singlemarks.angrymoti.R
import com.singlemarks.angrymoti.Route
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.TimePolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.map

/** 홈 셸 내부 내비게이션 */
sealed class HomeNav {
    data object Home : HomeNav()
    data object Calendar : HomeNav()
    data object MyPage : HomeNav()
    data class ReservationEdit(val reservationId: String?) : HomeNav()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeShell() {
    val context = LocalContext.current
    val owner = AccountStore.currentUserID
    val db = remember { AppDb.get(context) }
    var nav by remember { mutableStateOf<HomeNav>(HomeNav.Home) }
    var tab by remember { mutableStateOf("activity") }   // activity | schedule
    var showQuickStart by remember { mutableStateOf(false) }

    when (val n = nav) {
        is HomeNav.Calendar -> { CalendarScreen(onBack = { nav = HomeNav.Home }); return }
        is HomeNav.MyPage -> { MyPageScreen(onBack = { nav = HomeNav.Home }); return }
        is HomeNav.ReservationEdit -> {
            ReservationEditScreen(reservationId = n.reservationId, onDone = { nav = HomeNav.Home })
            return
        }
        HomeNav.Home -> {}
    }

    val total by db.scores().totalFlow(owner).collectAsState(initial = 0)
    val reservations by db.reservations().activeFlow(owner).collectAsState(initial = emptyList())

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        // 헤더 — 점수 배지 필(→기록) · 캘린더 원형 버튼 · 마이페이지 원형 버튼 (iOS 홈 헤더 1:1)
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .background(TL.surface, CircleShape)
                    .border(1.dp, TL.hairline, CircleShape)
                    .clickable { nav = HomeNav.Calendar }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            ) {
                Image(
                    painterResource(if (total >= 0) R.drawable.moti_smile else R.drawable.moti_angry),
                    null, Modifier.size(30.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    TLFormat.scoreLabel(total),
                    color = if (total >= 0) TL.jade else TL.rec,
                    fontSize = 22.sp, fontWeight = FontWeight.Black,
                )
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(46.dp).background(TL.surface, CircleShape)
                .border(1.dp, TL.hairline, CircleShape)
                .clickable { nav = HomeNav.Calendar }, contentAlignment = Alignment.Center) {
                Text("▦", color = TL.paper, fontSize = 20.sp)
            }
            Spacer(Modifier.width(10.dp))
            Box(Modifier.size(46.dp).background(TL.surface, CircleShape)
                .border(1.dp, TL.hairline, CircleShape)
                .clickable { nav = HomeNav.MyPage }, contentAlignment = Alignment.Center) {
                Text("👤", fontSize = 20.sp)
            }
        }

        Box(Modifier.weight(1f)) {
            if (tab == "activity") ActivityTab(
                reservations = reservations,
                onQuickStart = { showQuickStart = true },
                onAdd = { nav = HomeNav.ReservationEdit(null) },
                onEdit = { nav = HomeNav.ReservationEdit(it.id) },
            ) else WeeklyScheduleTab(
                reservations = reservations,
                onAdd = { nav = HomeNav.ReservationEdit(null) },
                onEdit = { nav = HomeNav.ReservationEdit(it.id) },
            )
        }

        // 하단 활동|일정 토글 — 선택된 쪽이 종이색 캡슐 + 잉크 텍스트 (iOS 1:1)
        Row(
            modifier = Modifier
                .padding(bottom = 20.dp)
                .align(Alignment.CenterHorizontally)
                .background(TL.raised, CircleShape)
                .border(1.dp, TL.hairline, CircleShape)
                .padding(5.dp),
        ) {
            listOf("activity" to "◉ 활동", "schedule" to "🕐 일정").forEach { (key, label) ->
                Box(
                    modifier = Modifier
                        .background(if (tab == key) TL.paper else TL.raised, CircleShape)
                        .clickable { tab = key }
                        .padding(horizontal = 26.dp, vertical = 12.dp),
                ) {
                    Text(label, color = if (tab == key) TL.ink else TL.muted,
                        fontSize = 16.sp, fontWeight = FontWeight.Black)
                }
            }
        }
    }

    if (showQuickStart) {
        ModalBottomSheet(onDismissRequest = { showQuickStart = false }, containerColor = TL.surface) {
            QuickStartSheet(onStart = { pending ->
                showQuickStart = false
                AppState.route.value = Route.MountGuide(pending)
            })
        }
    }
}

@Composable
private fun ActivityTab(
    reservations: List<Reservation>,
    onQuickStart: () -> Unit,
    onAdd: () -> Unit,
    onEdit: (Reservation) -> Unit,
) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // 다음 활동 대형 카드 — 이름 중앙 배치 (iOS 홈 1:1)
        item {
            val nextRes = reservations.minByOrNull { it.nextOccurrence() ?: Long.MAX_VALUE }
            Box(
                Modifier.fillMaxWidth().height(170.dp)
                    .background(TL.surface, TL.cornerL)
                    .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
                    .clickable { nextRes?.let(onEdit) },
                contentAlignment = Alignment.Center,
            ) {
                Text(nextRes?.name ?: "다짐을 예약해 보세요",
                    color = if (nextRes != null) TL.paper else TL.muted,
                    fontSize = 22.sp, fontWeight = FontWeight.Black,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 24.dp))
            }
        }
        item { TLPrimaryButton("활동 추가하기", onClick = onAdd) }
        item {
            Row(
                Modifier.fillMaxWidth()
                    .background(TL.surface, TL.cornerL)
                    .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
                    .clickable(onClick = onQuickStart)
                    .padding(horizontal = 20.dp, vertical = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("지금 바로 시작", color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text("›", color = TL.muted, fontSize = 22.sp)
            }
        }
        item { Text("예정된 활동", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black,
            modifier = Modifier.padding(top = 6.dp)) }
        if (reservations.isEmpty()) {
            item {
                TLCard {
                    Text("아직 예약된 활동이 없어요", color = TL.muted, fontSize = 14.sp)
                    Text("다짐을 예약하면 그 시각에 알람이 울려요.", color = TL.faint, fontSize = 12.sp)
                }
            }
        }
        items(reservations.sortedBy { it.nextOccurrence() ?: Long.MAX_VALUE }) { r ->
            val next = r.nextOccurrence(now)
            TLCard(onClick = { onEdit(r) }) {
                Row {
                    Column(Modifier.weight(1f)) {
                        Text(r.name, color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "🔔 ${nextLabel(next)} · ${TLFormat.durationLabel(r.durationMinutes)}" +
                                if (r.isRepeating) " · 매주 " + weekdayLabel(r.repeatWeekdays) else "",
                            color = TL.muted, fontSize = 12.sp,
                        )
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        if (next != null && next - now <= 12 * 3600_000L) {
                            Text(TLFormat.hms((next - now) / 1000), color = TL.amber,
                                fontSize = 18.sp, fontWeight = FontWeight.Black)
                            Spacer(Modifier.height(6.dp))
                        }
                        Box(Modifier.border(1.dp, TL.hairline, CircleShape)
                            .padding(horizontal = 12.dp, vertical = 5.dp)) {
                            Text(r.tag, color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(8.dp)) }
    }
}

fun nextLabel(next: Long?): String {
    if (next == null) return "예정 없음"
    val cal = java.util.Calendar.getInstance()
    val today = (cal.clone() as java.util.Calendar).apply {
        set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis
    val dayDiff = ((next - today) / 86_400_000L).toInt()
    val t = java.util.Calendar.getInstance().apply { timeInMillis = next }
    val minute = t.get(java.util.Calendar.HOUR_OF_DAY) * 60 + t.get(java.util.Calendar.MINUTE)
    val prefix = when (dayDiff) { 0 -> "오늘"; 1 -> "내일"; else -> "${t.get(java.util.Calendar.MONTH) + 1}월 ${t.get(java.util.Calendar.DAY_OF_MONTH)}일" }
    return "$prefix ${TLFormat.timeLabel(minute)}"
}

fun weekdayLabel(days: List<Int>): String {
    val names = mapOf(1 to "일", 2 to "월", 3 to "화", 4 to "수", 5 to "목", 6 to "금", 7 to "토")
    return days.sorted().joinToString("·") { names[it] ?: "" }
}

@Composable
private fun QuickStartSheet(onStart: (PendingSession) -> Unit) {
    var name by remember { mutableStateOf("") }
    var tag by remember { mutableStateOf(com.singlemarks.angrymoti.models.ActivityTag.presets.first()) }
    var minutes by remember { mutableStateOf(10) }

    Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
        Text("지금 바로 시작", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(16.dp))
        TLEyebrow("활동명 (필수)")
        androidx.compose.material3.OutlinedTextField(
            name, { name = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
            placeholder = { Text("무엇에 집중하나요?", color = TL.faint) },
            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline, cursorColor = TL.rec),
        )
        Spacer(Modifier.height(14.dp))
        TLEyebrow("태그")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            com.singlemarks.angrymoti.models.ActivityTag.presets.take(4).forEach { p ->
                TagChip(p, tag == p) { tag = p }
            }
        }
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            TLEyebrow("활동 시간")
            Spacer(Modifier.weight(1f))
            Text("완료 시 +${ScoreRules.completionBase(minutes)}점", color = TL.jade,
                fontSize = 12.sp, fontWeight = FontWeight.Black,
                modifier = Modifier.background(TL.jade.copy(alpha = 0.14f), CircleShape)
                    .padding(horizontal = 10.dp, vertical = 5.dp))
        }
        androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(TimePolicy.durationOptionsMinutes.size) { i ->
                val m = TimePolicy.durationOptionsMinutes[i]
                TagChip(TLFormat.durationLabel(m), minutes == m) { minutes = m }
            }
        }
        Spacer(Modifier.height(20.dp))
        if (name.isBlank()) {
            Text("활동명을 입력해야 시작할 수 있어요", color = TL.amber, fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 8.dp))
        }
        TLPrimaryButton("촬영 준비하기", enabled = name.isNotBlank()) {
            onStart(PendingSession(name.trim(), tag, minutes * 60))
        }
    }
}
