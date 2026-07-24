package com.singlemarks.angrymoti.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
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
    var tab by remember { mutableStateOf("activity") }   // activity | schedule | group
    var pendingGroupRoomId by remember { mutableStateOf<String?>(null) }   // 일정→그룹방 직접 진입
    var showQuickStart by remember { mutableStateOf(false) }
    var showGoalEditor by remember { mutableStateOf(false) }
    // 다짐 문구는 AccountStore flow를 구독 — 계정 전환·다른 기기 동기화가 즉시 반영된다
    val goalText by AccountStore.homeGoal.collectAsState()
    LaunchedEffect(owner) { AccountStore.reloadHomeGoal() }   // 계정 전환·최초 진입 시 로컬값 로드

    // 뒤로가기: 홈이 아닌 화면에서는 홈으로 복귀, 홈에서는 시스템 기본 동작(배경으로) 그대로 둔다
    BackHandler(enabled = nav != HomeNav.Home) { nav = HomeNav.Home }

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
    val sessions by db.sessions().allFlow(owner).collectAsState(initial = emptyList())

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
            // 기록 캘린더 — 원형 버튼 + 캘린더 아이콘 (iOS SF calendar 1:1)
            Box(Modifier.size(45.dp).background(TL.surface, CircleShape)
                .border(1.dp, TL.hairline, CircleShape)
                .clickable { nav = HomeNav.Calendar }, contentAlignment = Alignment.Center) {
                androidx.compose.material3.Icon(
                    AppIcon.CalendarDays,
                    contentDescription = "기록", tint = TL.paper,
                    modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.width(10.dp))
            // 마이페이지 — 배경 없는 사람 아이콘 (iOS person.crop.circle.fill 1:1)
            Box(Modifier.size(45.dp).background(TL.surface, CircleShape)
                .border(1.dp, TL.hairline, CircleShape)
                .clickable { nav = HomeNav.MyPage }, contentAlignment = Alignment.Center) {
                androidx.compose.material3.Icon(
                    AppIcon.UserRound,
                    contentDescription = "마이페이지", tint = TL.paper,
                    modifier = Modifier.size(21.dp))
            }
        }

        Box(Modifier.weight(1f)) {
            when (tab) {
                "activity" -> ActivityTab(
                    reservations = reservations,
                    sessions = sessions,
                    goal = goalText,
                    onEditGoal = { showGoalEditor = true },
                    onQuickStart = { showQuickStart = true },
                    onAdd = { nav = HomeNav.ReservationEdit(null) },
                    // 그룹 예약은 개인 편집 불가 — 그 그룹방 상세로 바로 진입
                    onEdit = {
                        if (it.groupId == null) nav = HomeNav.ReservationEdit(it.id)
                        else { pendingGroupRoomId = it.groupId; tab = "group" }
                    },
                )
                "group" -> GroupTab(
                    openRoomId = pendingGroupRoomId,
                    onRoomOpened = { pendingGroupRoomId = null },
                )
                else -> WeeklyScheduleTab(
                    reservations = reservations,
                    onAdd = { nav = HomeNav.ReservationEdit(null) },
                    onEdit = { nav = HomeNav.ReservationEdit(it.id) },
                    // 그룹 예약은 그 그룹방 상세로 바로 진입
                    onOpenGroup = { groupId -> pendingGroupRoomId = groupId; tab = "group" },
                )
            }
        }

        // 하단 활동|일정 토글 — 반투명 캡슐 + 아이콘, 선택된 쪽 종이색 캡슐 (iOS 글래스 토글 1:1)
        Row(
            modifier = Modifier
                .padding(bottom = 20.dp)
                .align(Alignment.CenterHorizontally)
                .shadow(18.dp, CircleShape, ambientColor = Color.Black, spotColor = Color.Black)
                .background(TL.raised.copy(alpha = 0.92f), CircleShape)
                .border(1.dp, Color.White.copy(alpha = 0.14f), CircleShape)
                .padding(6.dp),
        ) {
            val user by AccountStore.user.collectAsState()
            val isGuest = user?.provider == "guest"
            (if (isGuest) listOf(
                Triple("activity", "활동", AppIcon.CircleDot),
                Triple("schedule", "일정", AppIcon.Clock),
            ) else listOf(
                // 그룹 챌린지는 계정 필요 — 게스트에겐 탭 자체를 숨긴다 (iOS 동일)
                Triple("activity", "활동", AppIcon.CircleDot),
                Triple("schedule", "일정", AppIcon.Clock),
                Triple("group", "그룹", AppIcon.Users),
            )).forEach { (key, label, icon) ->
                val selected = tab == key
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .background(if (selected) TL.paper else Color.Transparent, CircleShape)
                        .clickable { tab = key }
                        .padding(horizontal = if (isGuest) 28.dp else 19.dp, vertical = 14.dp),
                ) {
                    androidx.compose.material3.Icon(icon, null,
                        tint = if (selected) TL.ink else TL.paper.copy(alpha = 0.72f),
                        modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(label, color = if (selected) TL.ink else TL.paper.copy(alpha = 0.72f),
                        fontSize = 18.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }

    if (showGoalEditor) {
        ModalBottomSheet(onDismissRequest = { showGoalEditor = false }, containerColor = TL.surface) {
            var draft by remember { mutableStateOf(goalText) }
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
                Text("나의 다짐", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(16.dp))
                androidx.compose.material3.OutlinedTextField(
                    draft, { draft = it }, modifier = Modifier.fillMaxWidth(),
                    minLines = 3, maxLines = 5,
                    placeholder = { Text("예: 올해는 매일 2시간씩 공부한다", color = TL.faint) },
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                        focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline,
                        cursorColor = TL.rec),
                )
                Spacer(Modifier.height(16.dp))
                TLPrimaryButton("저장") {
                    AccountStore.saveHomeGoal(draft.trim())   // 로컬+flow+클라우드 한 번에
                    showGoalEditor = false
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
    sessions: List<com.singlemarks.angrymoti.data.FocusSession>,
    goal: String,
    onEditGoal: () -> Unit,
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
        // 다짐/목표 카드 — 탭하면 입력 시트 (iOS 홈 1:1)
        item {
            Box(
                Modifier.fillMaxWidth()
                    .heightIn(min = 140.dp)
                    .background(TL.surface, TL.cornerL)
                    .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
                    .clickable(onClick = onEditGoal),
                contentAlignment = Alignment.Center,
            ) {
                if (goal.isEmpty()) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(16.dp)) {
                        Text("나의 다짐, 목표를 적어보세요",
                            color = TL.faint, fontSize = 17.sp, fontWeight = FontWeight.Black)
                        Spacer(Modifier.height(6.dp))
                        Text("탭해서 작성", color = TL.faint, fontSize = 12.sp)
                    }
                } else {
                    Text(goal, color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        lineHeight = 26.sp,
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 16.dp))
                }
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
                Text("지금 바로 시작", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                androidx.compose.material3.Icon(
                    AppIcon.ChevronRight,
                    null, tint = TL.paper, modifier = Modifier.size(18.dp))
            }
        }
        item { Text("오늘 예정된 활동", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black,
            modifier = Modifier.padding(top = 6.dp)) }
        // 오늘 발생하는 활동 — 일정 탭 오늘 칸과 동일한 occurrenceOn() 기준.
        // 그룹의 오늘치 시각이 이미 지나도(nextOccurrence는 다음 주를 가리켜 사라지던 버그) 그대로 노출.
        // 단, 오늘 이미 촬영을 시작(완료·실패·진행)한 활동은 '할 일'이 아니므로 뺀다.
        val todayStart = java.util.Calendar.getInstance().apply {
            timeInMillis = now
            set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
        }.timeInMillis
        val dayEnd = todayStart + 86_400_000L
        fun startedToday(r: Reservation) = sessions.any { s ->
            s.reservationID == r.id && s.scheduledAt?.let { it in todayStart until dayEnd } == true
        }
        val todayReservations = reservations
            .mapNotNull { r -> r.occurrenceOn(todayStart)?.let { r to it } }
            .filter { !startedToday(it.first) }
            .sortedBy { it.second }.map { it.first }
        if (todayReservations.isEmpty()) {
            item {
                TLCard {
                    Text("오늘은 예정된 활동이 없어요. 이번 주 계획은 일정 탭에서 확인할 수 있어요.",
                        color = TL.muted, fontSize = 13.sp)
                }
            }
        }
        items(todayReservations) { r ->
            val next = r.occurrenceOn(todayStart)   // 오늘치 시각(지났으면 과거값 → 타이머 자동 off)
            // iOS 예약 카드 1:1 — 1행: 이름 + (12시간 내 타이머 or 태그 칩) / 2행: 🔔 시각 + (타이머면 칩)
            val showsTimer = next != null && next - now in 1..(12 * 3600_000L)
            TLCard(onClick = { onEdit(r) }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(r.name, color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f))
                    if (showsTimer) {
                        // 분단위 문구 — 1분 미만 "곧 시작", 그 외 "시작까지 …남음". 올림.
                        val secs = (next!! - now) / 1000
                        val label = if (secs < 60) "곧 시작" else {
                            val m = kotlin.math.ceil(secs / 60.0).toLong()
                            val time = if (m >= 60)
                                (if (m % 60 == 0L) "${m / 60}시간" else "${m / 60}시간 ${m % 60}분")
                            else "${m}분"
                            "시작까지 $time 남음"
                        }
                        Text(label, color = TL.amber, fontSize = 13.sp,
                            fontWeight = FontWeight.Black, maxLines = 1)
                    } else {
                        TagChip(r.tag, selected = false, onClick = { onEdit(r) })
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // 오늘 것만 보여주므로 날짜(오늘·내일·M월 D일)는 생략하고 시각만.
                    val t = java.util.Calendar.getInstance().apply { timeInMillis = next ?: now }
                    val minute = t.get(java.util.Calendar.HOUR_OF_DAY) * 60 + t.get(java.util.Calendar.MINUTE)
                    Text(
                        "🔔 ${TLFormat.timeLabel(minute)} · ${TLFormat.durationLabel(r.durationMinutes)}" +
                            if (r.isRepeating) " · 매주 " + weekdayLabel(r.repeatWeekdays) else "",
                        color = TL.muted, fontSize = 13.sp,
                        modifier = Modifier.weight(1f),
                    )
                    if (showsTimer) TagChip(r.tag, selected = false, onClick = { onEdit(r) })
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
