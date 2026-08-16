package com.singlemarks.angrymoti.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.FocusSession
import com.singlemarks.angrymoti.models.CanonicalTag
import com.singlemarks.angrymoti.models.ScoreNote
import com.singlemarks.angrymoti.models.DayOutcome
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.ui.theme.TL
import java.io.File
import java.util.Calendar

/** 기록 탭 — 연속달성 헤더 카드(+태그 도넛 토글) · 성취 아이콘 월간 캘린더 · 누적 대시보드 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun CalendarScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    val owner = AccountStore.currentUserID
    val sessions by db.sessions().allFlow(owner).collectAsState(initial = emptyList())
    val events by db.scores().allFlow(owner).collectAsState(initial = emptyList())
    val todayStart = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }
    var month by remember { mutableStateOf(Calendar.getInstance()) }
    // 날짜 상세 시트 대상 — 기록 있는 날을 탭했을 때만 열린다 (iOS 1:1)
    var selectedDay by remember { mutableStateOf<Long?>(null) }

    val finished = sessions.filter { it.outcome != null }

    // 그날의 성취 아이콘 판정용 — 셀(≈30개)마다 전수 필터하지 않도록 한 번만 날짜별로 묶는다.
    val sessionsByDay: Map<Long, List<FocusSession>> = remember(finished) {
        finished.groupBy { DayOutcome.startOfDay(it.anchorAt) }
    }

    // 헤더(뒤로가기·'기록')는 스크롤 밖 고정 — 아래로 내려가도 맨 위로 돌아오지 않고
    // 바로 뒤로 갈 수 있다.
    Column(Modifier.fillMaxSize().background(TL.ink)) {
        Box(Modifier.padding(horizontal = 20.dp).padding(top = 14.dp, bottom = 6.dp)) {
            TLScreenHeader(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.history), onBack = onBack)
        }
        LazyColumn(Modifier.weight(1f).padding(horizontal = 20.dp)) {
        item {
            StreakHeaderCard(sessions = sessions)
            Spacer(Modifier.height(20.dp))
        }
        item {
            // 캘린더 전체가 하나의 큰 카드 — 셀에는 배경을 깔지 않는다(타일 격자 느낌 방지).
            // 오늘·선택된 날만 raised 박스로 표시한다 (iOS monthGrid 1:1).
            Column(
                Modifier.fillMaxWidth().background(TL.surface, TL.cornerL).padding(16.dp),
            ) {
                // 월 네비게이션 — chevron 아이콘 (iOS 1:1)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(32.dp).clip(TL.cornerS).clickable {
                        month = (month.clone() as Calendar).apply { add(Calendar.MONTH, -1) }
                    }, contentAlignment = Alignment.Center) {
                        androidx.compose.material3.Icon(AppIcon.ChevronLeft, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.prev_month),
                            tint = TL.muted, modifier = Modifier.size(22.dp))
                    }
                    Spacer(Modifier.weight(1f))
                    Text(TLFormat.yearMonth(month.timeInMillis),
                        color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.weight(1f))
                    Box(Modifier.size(32.dp).clip(TL.cornerS).clickable {
                        month = (month.clone() as Calendar).apply { add(Calendar.MONTH, 1) }
                    }, contentAlignment = Alignment.Center) {
                        androidx.compose.material3.Icon(AppIcon.ChevronRight, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.next_month),
                            tint = TL.muted, modifier = Modifier.size(22.dp))
                    }
                }
                Spacer(Modifier.height(14.dp))
                Row(Modifier.fillMaxWidth()) {
                    TLFormat.weekdaySymbols.forEach {
                        Text(it, color = TL.faint, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            modifier = Modifier.weight(1f))
                    }
                }
                Spacer(Modifier.height(8.dp))
                val first = (month.clone() as Calendar).apply {
                    set(Calendar.DAY_OF_MONTH, 1)
                    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                    set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                }
                val lead = first.get(Calendar.DAY_OF_WEEK) - 1
                val daysInMonth = month.getActualMaximum(Calendar.DAY_OF_MONTH)
                val weeks = (lead + daysInMonth + 6) / 7
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    repeat(weeks) { w ->
                        Row(Modifier.fillMaxWidth()) {
                            repeat(7) { d ->
                                val day = w * 7 + d - lead + 1
                                Box(Modifier.weight(1f).height(56.dp), contentAlignment = Alignment.Center) {
                                    if (day in 1..daysInMonth) {
                                        // Calendar 기반 날짜 이동 — 밀리초 산술은 DST가 있는
                                        // 로케일에서 자정이 어긋나 sessionsByDay 키와 미스매치된다
                                        val dayStart = com.singlemarks.angrymoti.models
                                            .ScheduleConflict.addDays(first.timeInMillis, day - 1)
                                        val daySessions = sessionsByDay[dayStart].orEmpty()
                                        // 그날의 성취 아이콘 — 홈 연속달성 스트립과 같은 판정(DayOutcome) 하나를 쓴다.
                                        // 캘린더에서는 미시작/미래를 굳이 그리지 않는다 — 기록 있는 날만 아이콘.
                                        val judged = DayOutcome.judge(daySessions, dayStart)
                                        val icon = if (judged == DayOutcome.NOT_STARTED) null else judged
                                        val isToday = dayStart == todayStart
                                        // 셀 배경은 오늘만 raised — 빨간 테두리·빨간 숫자
                                        // 강조는 쓰지 않는다. 탭은 기록 있는 날만 상세 시트를 연다 (iOS dayCell 1:1)
                                        Column(
                                            horizontalAlignment = Alignment.CenterHorizontally,
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(horizontal = 3.dp)   // 셀 사이 간격 (iOS grid spacing 6)
                                                .clip(TL.cornerS)
                                                .background(
                                                    if (isToday) TL.raised
                                                    else androidx.compose.ui.graphics.Color.Transparent,
                                                    TL.cornerS)
                                                .clickable {
                                                    if (daySessions.isNotEmpty()) selectedDay = dayStart
                                                }
                                                .padding(vertical = 6.dp),
                                        ) {
                                            Text("$day", color = if (isToday) TL.paper else TL.muted,
                                                fontSize = 14.sp, fontWeight = FontWeight.Bold)
                                            Spacer(Modifier.height(4.dp))
                                            if (icon != null) {
                                                Image(painterResource(dayOutcomeDrawable(icon)), null,
                                                    Modifier.size(17.dp))
                                            } else {
                                                Box(Modifier.padding(vertical = 6.5.dp).size(4.dp)
                                                    .background(TL.hairline.copy(alpha = 0.4f), CircleShape))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
        }
        item {
            // 누적 대시보드 — 카드 1장: 좌측 큰 총점, 우측 2×2 (상점/완주율 · 벌점/노쇼율).
            // 연속달성·태그 분포는 상단 헤더 카드로 이사했다 (iOS 1:1).
            TLEyebrow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cumulative_dashboard))
            val done = finished.size
            val successes = finished.count { it.outcome!!.isSuccess }
            val noShows = finished.count { it.outcome == com.singlemarks.angrymoti.models.SessionOutcome.NO_SHOW }
            val plus = events.filter { it.points > 0 }.sumOf { it.points }
            val minusSum = events.filter { it.points < 0 }.sumOf { it.points }
            val total = plus + minusSum
            // 완주율 분모는 '시작한 세션'(startedAt 있음) — 노쇼는 시작 자체를 안 한 것이라
            // 분모에 넣으면 노쇼가 많을수록 완주율이 이중으로 깎여 보인다 (iOS 1:1)
            val started = finished.count { it.startedAt != null }
            val completeRate = if (started > 0) successes * 100 / started else 0
            val noShowRate = if (done > 0) noShows * 100 / done else 0

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
                    .background(TL.surface, TL.cornerL).padding(16.dp),
            ) {
                Column {
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.total_score), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text("$total", color = if (total >= 0) TL.jade else TL.rec,
                            fontSize = 36.sp, fontWeight = FontWeight.Black, maxLines = 1)
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.pts_unit), color = TL.muted, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(start = 4.dp, bottom = 5.dp))
                    }
                }
                Spacer(Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                        MiniStat(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.total_points), "$plus", TL.jade)
                        MiniStat(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.completion_rate), "$completeRate%", TL.jade)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                        // 벌점은 빨간색이 이미 '깎였다'를 말하므로 절대값으로 표기
                        MiniStat(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.total_penalty), "${kotlin.math.abs(minusSum)}", TL.rec)
                        MiniStat(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.no_show_rate), "$noShowRate%", if (noShowRate > 0) TL.rec else TL.muted)
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
        item { Spacer(Modifier.height(24.dp)) }
        }
    }

    // 날짜 상세 — iOS DayDetailView처럼 시트로 띄운다 (기록 있는 날만 열린다)
    selectedDay?.let { dayStart ->
        androidx.compose.material3.ModalBottomSheet(
            onDismissRequest = { selectedDay = null },
            containerColor = TL.ink,
        ) {
            DayDetailSheet(dayStart = dayStart,
                sessions = sessionsByDay[dayStart].orEmpty(),
                events = events,
                onClose = { selectedDay = null })
        }
    }
}

/** 대시보드 우측 2×2 통계 한 칸 (iOS miniStat 1:1) */
@Composable
private fun MiniStat(label: String, value: String, tint: androidx.compose.ui.graphics.Color) {
    Column(horizontalAlignment = Alignment.End, modifier = Modifier.width(58.dp)) {
        Text(label, color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(2.dp))
        Text(value, color = tint, fontSize = 16.sp, fontWeight = FontWeight.Black, maxLines = 1)
    }
}

/**
 * 연속달성 헤더 카드 (+ 태그별 시간 분포 도넛 토글).
 * 도넛은 기본 접힘 — 펼치지 않는 한 캘린더가 아래로 밀리지 않는다 (iOS StreakHeaderCard 1:1).
 */
@Composable
private fun StreakHeaderCard(sessions: List<FocusSession>) {
    var showTagDonut by remember { mutableStateOf(false) }

    val detail = remember(sessions) { SlotPolicy.streakDetail(sessions) }
    val best = remember(sessions) { SlotPolicy.bestStreak(sessions) }
    val successSessions = remember(sessions) { sessions.filter { it.outcome?.isSuccess == true } }
    // 누적 완주 시간(초) — 홈 상단 배지와 같은 정의
    val totalSeconds = remember(successSessions) { successSessions.sumOf { it.recordedSeconds } }
    // 평균 일정 = 현재 연속달성 기간에 성공한 일정 수 ÷ 연속일수.
    // (예: 월 3개·화 1개·수 2개 성공으로 3일 연속이면 6÷3 = 2.0개)
    val averageLabel = if (detail.first > 0)
        "%.1f".format(detail.second.toDouble() / detail.first) else "0.0"
    val byTag: List<Pair<String, Int>> = remember(successSessions) {
        successSessions.groupBy { CanonicalTag.canonical(it.tag) }   // 레거시 한글·키가 한 조각으로 합쳐지게
            .mapValues { (_, list) -> list.sumOf { it.recordedSeconds } }
            // 동률 시 태그명 2차 정렬 — 상위 4개/'그 외' 구성이 실행·플랫폼마다
            // 달라지지 않게 한다 (iOS 동일)
            .toList().sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })
    }

    Column(
        // 접힘/펼침과 무관하게 카드가 항상 화면 폭을 꽉 채운다 —
        // 내용 크기에 폭을 맡기면 도넛을 여는 순간 카드 좌우 폭이 널뛴다
        Modifier.fillMaxWidth()
            .clip(TL.cornerL)   // 펼쳐지는 내용이 카드 밖으로 새어 그려지지 않게
            .background(TL.surface, TL.cornerL)
            .animateContentSize(tween(240))
            .padding(16.dp),
    ) {
        Row(Modifier.fillMaxWidth()) {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // 좁은 화면에서 두 줄로 꺾이지 않게 — 라벨은 항상 한 줄 (홈 카드와 동일)
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.streak), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                        maxLines = 1, softWrap = false)
                    Spacer(Modifier.width(5.dp))
                    Image(painterResource(com.singlemarks.angrymoti.R.drawable.stat_fire), null,
                        Modifier.size(15.dp))
                }
                Spacer(Modifier.height(5.dp))
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("${detail.first}", color = TL.jade, fontSize = 36.sp,
                        fontWeight = FontWeight.Black, maxLines = 1)
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.days_unit), color = TL.muted, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(start = 2.dp, bottom = 5.dp))
                }
                Spacer(Modifier.height(5.dp))
                // "총 N시간 n분을 기록했어요!" — 1시간 미만도 0시간이 아니라 분으로 보인다
                Row {
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.logged_prefix), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    hourMinuteParts(totalSeconds).forEachIndexed { i, (value, unit) ->
                        if (i > 0) Text(" ", fontSize = 13.sp)
                        Text(value, color = TL.jade, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Text(unit, color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.logged_suffix), color = TL.muted, fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // 아이콘 배정: 최고기록 = 별(stat_average), 평균 일정 = 깃발(stat_record).
                // 에셋 파일명과 화면 배정이 어긋나 있으니 이름만 보고 되돌리지 말 것 (iOS 동일).
                SideStat(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.best_streak), com.singlemarks.angrymoti.R.drawable.stat_average, "$best", androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.days_unit))
                SideStat(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.avg_per_day), com.singlemarks.angrymoti.R.drawable.stat_record, averageLabel, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.count_unit))
            }
        }

        // 카드 높이가 자라는 만큼만 도넛이 드러난다(clip + animateContentSize) —
        // 위에서 미끄러져 내려오는 전환은 헤더 숫자 위를 훑고 지나가 어수선했다.
        if (showTagDonut && byTag.isNotEmpty()) {
            Box(Modifier.padding(top = 18.dp)) { TagDonut(byTag) }
        }

        // 토글 손잡이 — 태그별 시간 분포 열기/닫기
        if (byTag.isNotEmpty()) {
            Box(
                Modifier.fillMaxWidth()
                    .clickable { showTagDonut = !showTagDonut }
                    .padding(top = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                androidx.compose.material3.Icon(
                    if (showTagDonut) AppIcon.ChevronUp else AppIcon.ChevronDown, null,
                    tint = TL.faint, modifier = Modifier.size(20.dp))
            }
        }
    }
}

@Composable
private fun SideStat(label: String, icon: Int, value: String, unit: String) {
    Column(horizontalAlignment = Alignment.End) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(4.dp))
            Image(painterResource(icon), null, Modifier.size(14.dp))
        }
        Spacer(Modifier.height(3.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
            Text(unit, color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 2.dp, bottom = 2.dp))
        }
    }
}

/**
 * 태그별 시간 분포 도넛 — 상위 4개 + '그 외'.
 * 색은 시스템 태그 색(tagTint) 그대로라 칩과 조각이 같은 색을 말한다.
 * 폭이 넘치지 않는 구조여야 한다 — 넘치면 스크롤 내용 전체가 그 폭에 맞춰 늘어나
 * 이웃 카드(캘린더)까지 함께 넓어진다. 도넛은 고정 크기, 범례는 한 줄에 하나씩.
 */
@Composable
private fun TagDonut(byTag: List<Pair<String, Int>>) {
    // 프리셋 태그가 아닌 것(그룹·직접 입력·'그 외')용 폴백 — 서로 구분되는 무채색 계열
    val fallbackPalette = listOf(
        androidx.compose.ui.graphics.Color(0xFF9AA0A6),
        androidx.compose.ui.graphics.Color(0xFF6E7681),
        androidx.compose.ui.graphics.Color(0xFF4D555E),
    )
    val segments = remember(byTag) {
        val rows = byTag.take(4).toMutableList()
        val rest = byTag.drop(4).sumOf { it.second }
        if (rest > 0) rows.add(com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.other_tag) to rest)
        var fallbackIndex = 0
        rows.map { (name, seconds) ->
            val color = tagTint(name) ?: fallbackPalette[fallbackIndex++ % fallbackPalette.size]
            Triple(name, seconds, color)
        }
    }
    val totalSeconds = segments.sumOf { it.second }.coerceAtLeast(1)

    /** 시:분 표기 — "655:24" = 655시간 24분 (모든 활동이 5·10분 단위라 초는 표시하지 않는다) */
    fun hoursMinutes(seconds: Int) = "%d:%02d".format(seconds / 3600, (seconds % 3600) / 60)

    Column(Modifier.fillMaxWidth()) {
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.time_by_tag), color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.h_m_note), color = TL.faint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(14.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(150.dp), contentAlignment = Alignment.Center) {
                // 세그먼트 사이 미세 간격으로 조각을 분리해 읽기 쉽게 한다
                val gapDeg = if (segments.size > 1) 2.9f else 0f
                androidx.compose.foundation.Canvas(Modifier.size(140.dp)) {
                    val stroke = 24.dp.toPx()
                    val inset = stroke / 2
                    var startFraction = 0f
                    segments.forEach { (_, seconds, color) ->
                        val fraction = seconds.toFloat() / totalSeconds
                        val sweep = fraction * 360f - gapDeg
                        if (sweep > 0f) {
                            drawArc(
                                color = color,
                                startAngle = startFraction * 360f - 90f + gapDeg / 2,
                                sweepAngle = sweep,
                                useCenter = false,
                                topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
                                size = androidx.compose.ui.geometry.Size(
                                    size.width - stroke, size.height - stroke),
                                style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                            )
                        }
                        startFraction += fraction
                    }
                }
                // 점유율 라벨 — 조각 중앙 각도에 배치 (7% 미만 조각은 생략해 겹침 방지)
                var running = 0f
                segments.forEach { (_, seconds, _) ->
                    val fraction = seconds.toFloat() / totalSeconds
                    val mid = (running + fraction / 2) * 2 * Math.PI - Math.PI / 2
                    running += fraction
                    if (fraction >= 0.07f) {
                        Text("${kotlin.math.round(fraction * 100).toInt()}%",
                            color = androidx.compose.ui.graphics.Color.White,
                            fontSize = 11.sp, fontWeight = FontWeight.Black,
                            modifier = Modifier.offset(   // 링 중심선(반경 58) 위
                                x = (kotlin.math.cos(mid) * 58).dp,
                                y = (kotlin.math.sin(mid) * 58).dp))
                    }
                }
                // 중앙 — 총 n분
                Column(horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.width(78.dp)) {
                    androidx.compose.material3.Icon(AppIcon.Clock, null,
                        tint = TL.faint, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.height(3.dp))
                    Row {
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.total_prefix), color = TL.muted, fontSize = 14.sp, fontWeight = FontWeight.Black)
                        Text("%,d".format(totalSeconds / 60), color = TL.jade,
                            fontSize = 14.sp, fontWeight = FontWeight.Black, maxLines = 1)
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.m_unit), color = TL.muted, fontSize = 14.sp, fontWeight = FontWeight.Black)
                    }
                }
            }

            Spacer(Modifier.width(14.dp))

            // 범례 — 태그 칩(앱 전역과 동일) + 시:분. 한 줄에 하나씩이라 항상 압축 가능하다.
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                segments.forEach { (name, seconds, _) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.widthIn(max = 96.dp)) {
                            TagChip(name, selected = false, onClick = {})
                        }
                        Spacer(Modifier.weight(1f))
                        Text(hoursMinutes(seconds), color = TL.muted,
                            fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                    }
                }
            }
        }
    }
}

/**
 * 날짜 상세 시트 — 성적표 스타일 (iOS DayDetailView 1:1).
 * 상단: 모두 펼치기/접기 · 날짜 타이틀 · 닫기 / 요약 칩(상점·벌점·합계) /
 * 카드 한 장에 구분선으로 나뉜 행들(접힘: 원·시각·활동·점수 / 펼침: 결과·썸네일·사유·순수촬영).
 */
@Composable
private fun DayDetailSheet(
    dayStart: Long,
    sessions: List<FocusSession>,
    events: List<com.singlemarks.angrymoti.data.ScoreEvent>,
    onClose: () -> Unit,
) {
    val ordered = remember(sessions) { sessions.sortedBy { it.anchorAt } }
    var expanded by remember(dayStart) { mutableStateOf(setOf<String>()) }
    val allOpen = ordered.isNotEmpty() && expanded.size == ordered.size

    fun pts(s: FocusSession): Int? =
        s.outcome?.let { ScoreRules.points(it, s.intensity, s.targetSeconds / 60)?.second }
    val dayReward = ordered.mapNotNull { pts(it) }.filter { it > 0 }.sum()
    val dayPenalty = ordered.mapNotNull { pts(it) }.filter { it < 0 }.sum()
    val dayTitle = remember(dayStart) { TLFormat.dayTitle(dayStart) }

    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
        item {
            // 상단 바 — 좌 모두 펼치기/접기, 중앙 날짜, 우 닫기 (iOS 툴바 1:1)
            Box(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
                if (ordered.isNotEmpty()) {
                    // '모두 접기'↔'모두 펼치기' 글자 수 차이로 버튼이 움직이지 않게 고정 폭 + 가운데
                    Box(Modifier.align(Alignment.CenterStart)
                        .clickable {
                            expanded = if (allOpen) emptySet() else ordered.map { it.id }.toSet()
                        },
                        contentAlignment = Alignment.Center) {
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.expand_all), fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                            color = androidx.compose.ui.graphics.Color.Transparent)   // 폭 기준
                        Text(if (allOpen) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.collapse_all) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.expand_all),
                            color = TL.muted, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                            maxLines = 1)
                    }
                }
                Text(dayTitle, color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.align(Alignment.Center))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.close), color = TL.muted, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.CenterEnd).clickable(onClick = onClose))
            }
        }
        item {
            // 상단 합계 — 성적표 헤더 (iOS summaryHeader 1:1)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SummaryChip("+$dayReward", androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.points), TL.jade, Modifier.weight(1f))
                SummaryChip("$dayPenalty", androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.penalty), TL.rec, Modifier.weight(1f))
                SummaryChip("${dayReward + dayPenalty}", androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.total),
                    if (dayReward + dayPenalty >= 0) TL.paper else TL.rec, Modifier.weight(1f))
            }
            Spacer(Modifier.height(16.dp))
        }
        item {
            TLCard {
                ordered.forEachIndexed { index, s ->
                    ReportRow(s, events,
                        isOpen = s.id in expanded,
                        onToggle = {
                            expanded = if (s.id in expanded) expanded - s.id else expanded + s.id
                        })
                    if (index != ordered.lastIndex) {
                        androidx.compose.material3.HorizontalDivider(
                            color = TL.hairline.copy(alpha = 0.5f))
                    }
                }
            }
        }
    }
}

@Composable
private fun SummaryChip(value: String, label: String,
                        tint: androidx.compose.ui.graphics.Color, modifier: Modifier) {
    Column(horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier.background(TL.surface, TL.cornerM).padding(vertical = 12.dp)) {
        Text(value, color = tint, fontSize = 20.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(3.dp))
        Text(label, color = TL.muted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 접힘: 성취 원·시작 시각·활동명·점수·화살표 / 펼침: 결과·강도·썸네일·사유·순수촬영시간 (iOS reportRow 1:1) */
@Composable
private fun ReportRow(
    s: FocusSession,
    events: List<com.singlemarks.angrymoti.data.ScoreEvent>,
    isOpen: Boolean,
    onToggle: () -> Unit,
) {
    val context = LocalContext.current
    val outcome = s.outcome
    val pts = outcome?.let { ScoreRules.points(it, s.intensity, s.targetSeconds / 60)?.second }
    // 상세 행의 성취 원은 3색 — 성공 초록 / 실패(이탈·노쇼·긴급) 빨강 / 안전 종료만 앰버 (iOS 1:1).
    // 앰버(중립)는 기기 사정으로 무효 처리된 안전 종료에만 쓴다 — 긴급 종료는 사용자가
    // 스스로 그만둔 실패라 빨강이다.
    val circleColor = when {
        outcome?.isSuccess == true -> TL.jade
        outcome?.isFailure == true -> TL.rec
        else -> TL.amber
    }

    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(vertical = 13.dp),
        ) {
            Box(Modifier.size(16.dp).background(circleColor, CircleShape)
                .border(3.dp, circleColor.copy(alpha = 0.35f), CircleShape))
            Spacer(Modifier.width(12.dp))
            // 시각은 한 줄 고정 폭 — 좁혀서 "오후/8:27" 두 줄로 꺾이지 않게 (iOS width 70)
            Text(TLFormat.clock(s.anchorAt), color = TL.paper, fontSize = 14.sp,
                fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false,
                modifier = Modifier.width(74.dp))
            Text(s.activityName, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, modifier = Modifier.weight(1f))
            pts?.let {
                Text(TLFormat.scoreLabel(it), color = if (it > 0) TL.jade else TL.rec,
                    fontSize = 14.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.width(8.dp))
            }
            androidx.compose.material3.Icon(
                if (isOpen) AppIcon.ChevronUp else AppIcon.ChevronDown, null,
                tint = TL.faint, modifier = Modifier.size(15.dp))
        }

        if (isOpen) {
            Column(Modifier.padding(start = 28.dp, bottom = 13.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(outcome?.title ?: "", color = circleColor,
                        fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Text(" · ${s.intensity.title}", color = TL.muted, fontSize = 12.sp)
                }
                Spacer(Modifier.height(8.dp))
                s.thumbnailFileName?.let { name ->
                    // IO 스레드에서 디코드 — 컴포지션 중 파일 디코드는 프레임 드랍을 만든다
                    val thumb by androidx.compose.runtime.produceState<android.graphics.Bitmap?>(null, name) {
                        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            runCatching {
                                android.graphics.BitmapFactory.decodeFile(
                                    File(CameraRecorder.sessionDir(context), name).absolutePath)
                            }.getOrNull()
                        }
                    }
                    thumb?.let {
                        Image(it.asImageBitmap(), null,
                            Modifier.fillMaxWidth().height(150.dp).clip(TL.cornerM),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                        Spacer(Modifier.height(8.dp))
                    }
                }
                // 실패/긴급 사유 — 점수 원장의 note 우선, 없으면 세션의 긴급 사유 (iOS 1:1).
                // 세션 사유만 보면 알람 화면의 '일정 취소' 사유(원장에만 기록)가 안 보인다.
                val reason = (events.firstOrNull { it.sessionID == s.id && !it.note.isNullOrEmpty() }?.note
                    ?: s.emergencyReason)?.let(ScoreNote::label)   // 정본 토큰·레거시 한글 모두 표시 문구로
                reason?.let {
                    Text(it, color = TL.amber, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                }
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.recorded_target, TLFormat.hms(s.recordedSeconds.toLong()), TLFormat.hms(s.targetSeconds.toLong())),
                    color = TL.muted, fontSize = 12.sp)
            }
        }
    }
}
