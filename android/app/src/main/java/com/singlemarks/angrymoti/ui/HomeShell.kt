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
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
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
import com.singlemarks.angrymoti.models.DayOutcome
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.models.SlotPolicy
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
    data object Paywall : HomeNav()
    data class ReservationEdit(val reservationId: String?) : HomeNav()
}

/** HomeNav ↔ 문자열 — rememberSaveable로 재생성에도 현재 화면을 지키기 위한 Saver */
private val HomeNavSaver = androidx.compose.runtime.saveable.Saver<HomeNav, String>(
    save = { n ->
        when (n) {
            HomeNav.Home -> "home"
            HomeNav.Calendar -> "calendar"
            HomeNav.MyPage -> "mypage"
            HomeNav.Paywall -> "paywall"
            is HomeNav.ReservationEdit -> "edit:${n.reservationId ?: ""}"
        }
    },
    restore = { s ->
        when {
            s == "calendar" -> HomeNav.Calendar
            s == "mypage" -> HomeNav.MyPage
            s == "paywall" -> HomeNav.Paywall
            s.startsWith("edit:") -> HomeNav.ReservationEdit(s.removePrefix("edit:").ifEmpty { null })
            else -> HomeNav.Home
        }
    },
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeShell() {
    val context = LocalContext.current
    val owner = AccountStore.currentUserID
    val db = remember { AppDb.get(context) }
    // rememberSaveable — 다크모드 전환 등 재생성에도 현재 화면·탭·시트 상태를 지킨다.
    // remember만 쓰면 마이페이지를 보다가 재생성되는 순간 홈 활동 탭으로 튕긴다.
    var nav by androidx.compose.runtime.saveable.rememberSaveable(stateSaver = HomeNavSaver) {
        mutableStateOf<HomeNav>(HomeNav.Home)
    }
    var tab by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("activity") }   // activity | schedule | group
    var pendingGroupRoomId by androidx.compose.runtime.saveable.rememberSaveable {
        mutableStateOf<String?>(null)   // 일정→그룹방 직접 진입
    }
    var showQuickStart by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    var showGoalEditor by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    // 다짐 문구는 AccountStore flow를 구독 — 계정 전환·다른 기기 동기화가 즉시 반영된다
    val goalText by AccountStore.homeGoal.collectAsState()
    LaunchedEffect(owner) { AccountStore.reloadHomeGoal() }   // 계정 전환·최초 진입 시 로컬값 로드

    // 뒤로가기: 홈이 아닌 화면에서는 홈으로 복귀, 홈에서는 시스템 기본 동작(배경으로) 그대로 둔다
    BackHandler(enabled = nav != HomeNav.Home) { nav = HomeNav.Home }

    when (val n = nav) {
        is HomeNav.Calendar -> { CalendarScreen(onBack = { nav = HomeNav.Home }); return }
        is HomeNav.MyPage -> { MyPageScreen(onBack = { nav = HomeNav.Home }); return }
        // 페이월도 다른 상세 화면처럼 셸 전체를 교체한다 — 탭 콘텐츠 자리만 갈아끼우면
        // 상단 헤더·하단 탭 캡슐이 페이월 위에 그대로 남는다.
        is HomeNav.Paywall -> { PaywallScreen(onBack = { nav = HomeNav.Home }); return }
        is HomeNav.ReservationEdit -> {
            ReservationEditScreen(reservationId = n.reservationId, onDone = { nav = HomeNav.Home })
            return
        }
        HomeNav.Home -> {}
    }

    val reservations by db.reservations().activeFlow(owner).collectAsState(initial = emptyList())
    val sessions by db.sessions().allFlow(owner).collectAsState(initial = emptyList())

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        // 헤더 — 누적 성공 시간 배지 필(→기록) · 마이페이지 아이콘 (iOS 홈 헤더 1:1).
        // iOS처럼 활동 탭에만 붙는다 — 일정·그룹 탭은 각자 제 타이틀을 갖고 있어서
        // 이 헤더까지 얹으면 상단이 두 겹이 된다.
        // 점수 배지는 누적 시간으로 교체: 홈에서 매일 마주하는 숫자는 벌점이 아니라 쌓인 시간이어야 한다.
        // (캘린더 원형 버튼은 제거 — 시간 배지와 연속달성 카드가 이미 기록탭 진입로다)
        if (tab == "activity") {
            val totalSuccessSeconds = remember(sessions) {
                sessions.filter { it.outcome?.isSuccess == true }.sumOf { it.recordedSeconds }
            }
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
                        .padding(horizontal = 16.dp, vertical = 9.dp),
                ) {
                    Image(painterResource(R.drawable.stat_clock), null, Modifier.size(26.dp))
                    Spacer(Modifier.width(8.dp))
                    // 숫자는 연속달성 일수(38sp)보다 낮은 위계로 — 홈의 주인공은 스트릭이다.
                    // "N시간 n분" — 1시간 미만도 0시간이 아니라 분으로 보인다.
                    hourMinuteParts(totalSuccessSeconds).forEachIndexed { i, (value, unit) ->
                        if (i > 0) Spacer(Modifier.width(3.dp))
                        Text(value, color = TL.jade, fontSize = 17.sp, fontWeight = FontWeight.Black,
                            maxLines = 1)
                        Text(unit, color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                Spacer(Modifier.weight(1f))
                // 마이페이지 — 전용 에셋. 멤버십은 별 배지 붙은 profile_member (iOS 1:1).
                // 멤버 에셋은 배지 폭만큼 가로가 넓다(31:20 vs 21:20) — 높이만 고정하고
                // 원본 비율대로 그린다.
                val isPro by com.singlemarks.angrymoti.services.SubscriptionManager.isPro.collectAsState()
                Image(
                    painterResource(if (isPro) R.drawable.profile_member else R.drawable.profile),
                    contentDescription = "마이페이지",
                    modifier = Modifier.height(45.dp)
                        .width(if (isPro) 70.dp else 47.dp)   // 45 × (31/20), 45 × (21/20)
                        .clip(RoundedCornerShape(12.dp))
                        .clickable { nav = HomeNav.MyPage })
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
                    onOpenCalendar = { nav = HomeNav.Calendar },
                    onOpenPaywall = { nav = HomeNav.Paywall },
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
            // 입력 중 재생성돼도 쓰던 문구를 잃지 않게 saveable
            var draft by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(goalText) }
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
    onOpenCalendar: () -> Unit,
    onOpenPaywall: () -> Unit,
    onEdit: (Reservation) -> Unit,
) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }

    // 멤버십 무료 체험 안내 배너 — 무료 회원(게스트 제외) 전용. 구독은 계정에 귀속되므로
    // 게스트에게는 결제 유도를 하지 않는다(로그인부터 해야 함).
    val user by AccountStore.user.collectAsState()
    val isPro by com.singlemarks.angrymoti.services.SubscriptionManager.isPro.collectAsState()
    val showsTrialInvite = user != null && user?.provider != "guest" && !isPro

    // 오늘 발생 활동 — 일정 탭 오늘 칸과 완전히 같은 기준(occurrenceOn 단일 판정).
    // 이미 완료(성공·실패)한 활동도 목록에 남긴다 — 흐림 처리 + 결과 점으로 '오늘 한 일'이
    // 보여야 하루가 쌓이는 감각이 든다. 미완료가 먼저, 완료는 아래로.
    // 1초 틱마다 예약×세션 전수 스캔을 반복하지 않도록, 입력(예약·세션·날짜)이 바뀔 때만
    // 다시 계산한다. 카운트다운 문구는 now로 매초 갱신되지만 목록 자체는 캐시된다.
    val todayStart = java.util.Calendar.getInstance().apply {
        timeInMillis = now
        set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis
    // Calendar 기반 — 밀리초 산술은 DST가 있는 로케일에서 25시간짜리 날의 꼬리를 놓친다
    val dayEnd = com.singlemarks.angrymoti.models.ScheduleConflict.addDays(todayStart, 1)
    val todayItems: List<Triple<Reservation, Long, SessionOutcome?>> =
        remember(reservations, sessions, todayStart) {
            // 오늘 이 예약의 확정 결과 — 기록이 여럿(긴급 중단 후 재촬영)이면 가장 나중 것.
            // null = 아직 시작 전(또는 진행 중 — 촬영 중엔 홈이 보일 일이 없다).
            fun todayOutcome(r: Reservation): SessionOutcome? = sessions
                .filter { s ->
                    s.reservationID == r.id && s.outcome != null &&
                        s.scheduledAt?.let { it in todayStart until dayEnd } == true
                }
                // 동률 시 세션 ID 사전순 — 스트립·캘린더의 발생 판정과 같은 규칙 (iOS 동일)
                .maxWithOrNull(compareBy({ it.endedAt ?: Long.MIN_VALUE }, { it.id }))?.outcome
            reservations
                .mapNotNull { r ->
                    val fire = r.occurrenceOn(todayStart) ?: return@mapNotNull null
                    Triple(r, fire, todayOutcome(r))
                }
                // 미완료 우선, 같은 그룹 안에서는 발생 시각순
                .sortedWith(compareBy({ it.third != null }, { it.second }))
        }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // 연속달성 카드 — 좌측 일수 + 우측 5일 스트립, 탭하면 기록탭 (iOS 홈 1:1)
        item {
            StreakCard(sessions = sessions, reservations = reservations,
                todayStart = todayStart, onClick = onOpenCalendar)
        }
        // 다짐/목표 카드 — 탭하면 입력 시트 (iOS 홈 1:1)
        item {
            Box(
                Modifier.fillMaxWidth()
                    .heightIn(min = 116.dp)   // 연속달성 카드가 들어온 만큼 다짐 카드는 낮게
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
        // 멤버십 무료 체험 배너 — 무료 회원 전용 (iOS 홈 1:1)
        if (showsTrialInvite) {
            item {
                // 체험 기간 문구는 Play 스토어 오퍼가 정본 — product flow를 구독해
                // 상품 조회가 끝난 뒤에도 문구가 따라 붙는다 (iOS freeTrialDescription 대응)
                val product by com.singlemarks.angrymoti.services.SubscriptionManager.product.collectAsState()
                val trial = remember(product) { com.singlemarks.angrymoti.services.SubscriptionManager.freeTrialLabel }
                Row(
                    Modifier.fillMaxWidth()
                        .background(TL.jade.copy(alpha = 0.12f), TL.cornerL)
                        .border(1.dp, TL.jade.copy(alpha = 0.4f), TL.cornerL)
                        .clickable(onClick = onOpenPaywall)
                        .padding(horizontal = 20.dp, vertical = 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("✨ 마음껏 멤버십 기능 체험하기",
                        color = TL.jade, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    trial?.let {
                        Spacer(Modifier.width(6.dp))
                        Text("($it)", color = TL.jade.copy(alpha = 0.9f),
                            fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Spacer(Modifier.weight(1f))
                    androidx.compose.material3.Icon(
                        AppIcon.ChevronRight,
                        null, tint = TL.jade, modifier = Modifier.size(18.dp))
                }
            }
        }
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
        item {
            Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(top = 6.dp)) {
                Text("오늘 예정된 활동", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.width(8.dp))
                val t = java.util.Calendar.getInstance().apply { timeInMillis = todayStart }
                Text("${t.get(java.util.Calendar.MONTH) + 1}월 ${t.get(java.util.Calendar.DAY_OF_MONTH)}일",
                    color = TL.faint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(bottom = 2.dp))
            }
        }
        // 그룹 방 시작일 전이거나 오늘치 시각이 지났어도, 일정 탭에 보이면 홈에도 똑같이 보인다.
        if (todayItems.isEmpty()) {
            item {
                TLCard {
                    Text("오늘은 예정된 활동이 없어요. 이번 주 계획은 일정 탭에서 확인할 수 있어요.",
                        color = TL.muted, fontSize = 13.sp)
                }
            }
        }
        items(todayItems) { (r, next, done) ->
            // iOS 예약 카드 1:1 — 1행: 이름 + (12시간 내 타이머 or 결과 점+태그 칩) / 2행: 🔔 시각
            val showsTimer = done == null && next - now in 1..(12 * 3600_000L)
            // 완료 결과 점 — 일정 탭의 불빛과 완전히 같은 규칙: 성공 초록, 그 외 전부 빨강.
            // 안전 종료(무효)도 빨강이다 — 무효는 벌점화만 안 되는 것이지 완주 실패는 같다.
            val doneTint: Color? = done?.let { if (it.isSuccess) TL.jade else TL.rec }
            TLCard(onClick = { onEdit(r) },
                // 완료한 활동은 흐림 처리로 목록에 남긴다 (일정 탭의 '지나감'과 동일 문법)
                modifier = Modifier.alpha(if (done == null) 1f else 0.42f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(r.name, color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f))
                    if (showsTimer) {
                        // 분단위 문구 — 1분 미만 "곧 시작", 그 외 "… 뒤 시작". 올림.
                        val secs = (next - now) / 1000
                        val label = if (secs < 60) "곧 시작" else {
                            val m = kotlin.math.ceil(secs / 60.0).toLong()
                            val time = if (m >= 60)
                                (if (m % 60 == 0L) "${m / 60}시간" else "${m / 60}시간 ${m % 60}분")
                            else "${m}분"
                            "$time 뒤 시작"
                        }
                        Text(label, color = TL.amber, fontSize = 13.sp,
                            fontWeight = FontWeight.Black, maxLines = 1)
                    } else {
                        doneTint?.let {
                            // 오늘 결과 점 — 태그 칩 왼편 (일정 탭과 동일 문법)
                            Box(Modifier.size(9.dp).background(it, CircleShape))
                            Spacer(Modifier.width(8.dp))
                        }
                        TagChip(r.tag, selected = false, onClick = { onEdit(r) })
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // 오늘 것만 보여주므로 날짜(오늘·내일·M월 D일)는 생략하고 시각만.
                    val t = java.util.Calendar.getInstance().apply { timeInMillis = next }
                    val minute = t.get(java.util.Calendar.HOUR_OF_DAY) * 60 + t.get(java.util.Calendar.MINUTE)
                    Text(
                        "🔔 ${TLFormat.timeLabel(minute)} · ${TLFormat.durationLabel(r.durationMinutes)}" +
                            repeatSuffix(r),
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

/** 연속달성 카드 — 좌측 일수 + 우측 5일 스트립(D-3 ~ 내일). 판정은 DayOutcome 하나 (iOS streakCard 1:1). */
@Composable
private fun StreakCard(
    sessions: List<com.singlemarks.angrymoti.data.FocusSession>,
    reservations: List<Reservation>,
    todayStart: Long,
    onClick: () -> Unit,
) {
    val streak = remember(sessions, todayStart) { SlotPolicy.currentStreak(sessions) }
    val weekdayNames = listOf("", "일", "월", "화", "수", "목", "금", "토")

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(TL.surface, TL.cornerL)
            .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
            .clickable(onClick = onClick)
            // 왼쪽 블록은 살짝 더 들여쓰고, 오른쪽은 요일 칸이 자체 여백을 갖고 있어 좁게
            .padding(start = 18.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
    ) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 좁은 화면에서 두 줄로 꺾이지 않게 — 라벨은 항상 한 줄 (iOS와 동일)
                Text("연속달성", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                    maxLines = 1, softWrap = false)
                Spacer(Modifier.width(5.dp))
                Image(painterResource(R.drawable.stat_fire), null, Modifier.size(15.dp))
            }
            Spacer(Modifier.height(3.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                Text("$streak", color = TL.jade, fontSize = 38.sp, fontWeight = FontWeight.Black,
                    maxLines = 1)
                Text("일", color = TL.muted, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 6.dp, start = 2.dp))
            }
        }

        Spacer(Modifier.weight(1f))

        // 최근 3일 + 오늘 + 내일. 판정은 기록 캘린더와 같은 규칙(DayOutcome) 하나.
        Row(verticalAlignment = Alignment.CenterVertically) {
            (-3..1).forEach { offset ->
                val day = com.singlemarks.angrymoti.models.ScheduleConflict.addDays(todayStart, offset)
                val dayEnd = com.singlemarks.angrymoti.models.ScheduleConflict.addDays(day, 1)
                val daySessions = sessions.filter { it.anchorAt in day until dayEnd }
                val icon = DayOutcome.judge(daySessions, day) ?: DayOutcome.NOT_STARTED
                // 기록도 없고 그날 발생 예정인 예약도 없으면 '비어 있는 날' — 회색 체크
                // 대신 대시로 그린다. 예정 여부는 알람과 같은 occurrenceOn 하나로 판정
                // (요일만 보면 시작일·종료일 게이트가 빠져 실제와 어긋난다).
                val isEmpty = daySessions.isEmpty() &&
                    reservations.none { it.occurrenceOn(day) != null }
                val isToday = offset == 0
                val d = java.util.Calendar.getInstance().apply { timeInMillis = day }

                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.width(44.dp)
                        .background(if (isToday) TL.raised else Color.Transparent, TL.cornerS)
                        .padding(vertical = 7.dp),
                ) {
                    Text(weekdayNames[d.get(java.util.Calendar.DAY_OF_WEEK)],
                        color = if (isToday) TL.paper else TL.faint,
                        fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(5.dp))
                    Box(Modifier.size(24.dp).alpha(if (offset > 0) 0.45f else 1f),   // 아직 오지 않은 날은 흐리게
                        contentAlignment = Alignment.Center) {
                        if (isEmpty) {
                            Box(Modifier.width(14.dp).height(5.dp)
                                .background(TL.faint, CircleShape))
                        } else {
                            Image(painterResource(dayOutcomeDrawable(icon)), null,
                                Modifier.size(24.dp))
                        }
                    }
                    Spacer(Modifier.height(5.dp))
                    Text("${d.get(java.util.Calendar.DAY_OF_MONTH)}",
                        color = if (isToday) TL.paper else TL.muted,
                        fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                // 열 사이 헤어라인 (마지막 열 제외)
                if (offset < 1) {
                    Box(Modifier.width(1.dp).height(30.dp)
                        .background(TL.hairline.copy(alpha = 0.35f)))
                }
            }
        }
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

/** 시작일=종료일(하루)이면 오늘이 곧 그 하루이므로 접미사가 필요 없다. 요일 전체면 "매일". */
fun repeatSuffix(r: Reservation): String {
    val end = r.endAt
    if (end != null) {
        val a = java.util.Calendar.getInstance().apply { timeInMillis = r.createdAt }
        val b = java.util.Calendar.getInstance().apply { timeInMillis = end }
        if (a.get(java.util.Calendar.YEAR) == b.get(java.util.Calendar.YEAR) &&
            a.get(java.util.Calendar.DAY_OF_YEAR) == b.get(java.util.Calendar.DAY_OF_YEAR)) return ""
    }
    // '매일' / '반복요일' 두 가지로만 표기 (기간이 짧으면 '매주'는 사실과 다름)
    return when {
        r.repeatWeekdays.size == 7 -> " · 매일"
        r.isRepeating -> " · 반복요일 " + weekdayLabel(r.repeatWeekdays)
        else -> ""
    }
}

@Composable
private fun QuickStartSheet(onStart: (PendingSession) -> Unit) {
    var name by remember { mutableStateOf("") }
    var tag by remember { mutableStateOf(com.singlemarks.angrymoti.models.ActivityTag.presets.first()) }
    var minutes by remember { mutableStateOf(60) }   // 기본 1시간 (iOS 1:1)

    Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
        Text("지금 바로 시작", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(16.dp))
        // 라벨 없이 입력창·태그가 바로 이어진다 (iOS QuickStartSheet 1:1)
        androidx.compose.material3.OutlinedTextField(
            name, { name = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
            placeholder = { Text("활동명 (예: 모의고사 풀기)", color = TL.faint) },
            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline, cursorColor = TL.rec),
        )
        Spacer(Modifier.height(14.dp))
        // 태그 프리셋 전부 — 가로 스크롤 (iOS 1:1, 4개만 잘라 보여주지 않는다)
        androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(com.singlemarks.angrymoti.models.ActivityTag.presets.size) { i ->
                val p = com.singlemarks.angrymoti.models.ActivityTag.presets[i]
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
        TLPrimaryButton("촬영 준비하기", enabled = name.isNotBlank()) {
            onStart(PendingSession(name.trim(), tag, minutes * 60))
        }
        // 경고는 버튼 아래 (iOS 1:1)
        if (name.isBlank()) {
            Text("활동명을 입력해야 시작할 수 있습니다.", color = TL.amber, fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp))
        }
    }
}
