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
import androidx.compose.foundation.layout.aspectRatio
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
import com.singlemarks.angrymoti.models.DayOutcome
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.ui.theme.TL
import java.io.File
import java.util.Calendar

/** 기록 탭 — 연속달성 헤더 카드(+태그 도넛 토글) · 성취 아이콘 월간 캘린더 · 누적 대시보드 */
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
    // 진입 시 오늘을 기본 선택 — iOS와 동일하게 오늘의 기록이 바로 보임
    var selectedDay by remember { mutableStateOf<Long?>(todayStart) }

    val finished = sessions.filter { it.outcome != null }

    // 그날의 성취 아이콘 판정용 — 셀(≈30개)마다 전수 필터하지 않도록 한 번만 날짜별로 묶는다.
    val sessionsByDay: Map<Long, List<FocusSession>> = remember(finished) {
        finished.groupBy { DayOutcome.startOfDay(it.anchorAt) }
    }

    LazyColumn(Modifier.fillMaxSize().background(TL.ink).padding(horizontal = 20.dp)) {
        item {
            Box(Modifier.padding(top = 14.dp)) { TLScreenHeader("기록", onBack = onBack) }
        }
        item {
            StreakHeaderCard(sessions = sessions)
            Spacer(Modifier.height(20.dp))
        }
        item {
            // 캘린더 전체가 하나의 큰 카드 (iOS 1:1)
            TLCard(raised = true) {
                // 월 네비게이션
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("‹", color = TL.muted, fontSize = 22.sp, modifier = Modifier.clickable {
                        month = (month.clone() as Calendar).apply { add(Calendar.MONTH, -1) }
                    }.padding(horizontal = 10.dp))
                    Spacer(Modifier.weight(1f))
                    Text("${month.get(Calendar.YEAR)}년 ${month.get(Calendar.MONTH) + 1}월",
                        color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.weight(1f))
                    Text("›", color = TL.muted, fontSize = 22.sp, modifier = Modifier.clickable {
                        month = (month.clone() as Calendar).apply { add(Calendar.MONTH, 1) }
                    }.padding(horizontal = 10.dp))
                }
                Spacer(Modifier.height(14.dp))
                Row(Modifier.fillMaxWidth()) {
                    listOf("일", "월", "화", "수", "목", "금", "토").forEach {
                        Text(it, color = TL.faint, fontSize = 12.sp,
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
                                        val dayStart = first.timeInMillis + (day - 1) * 86_400_000L
                                        val daySessions = sessionsByDay[dayStart].orEmpty()
                                        // 그날의 성취 아이콘 — 홈 연속달성 스트립과 같은 판정(DayOutcome) 하나를 쓴다.
                                        // 캘린더에서는 미시작/미래를 굳이 그리지 않는다 — 기록 있는 날만 아이콘.
                                        val judged = DayOutcome.judge(daySessions, dayStart)
                                        val icon = if (judged == DayOutcome.NOT_STARTED) null else judged
                                        val isSelected = selectedDay == dayStart
                                        val isToday = dayStart == todayStart
                                        Column(
                                            horizontalAlignment = Alignment.CenterHorizontally,
                                            modifier = Modifier
                                                .background(if (isSelected) TL.raised else TL.surface, TL.cornerS)
                                                .let {
                                                    if (isToday) it.border(1.5.dp, TL.rec, TL.cornerS) else it
                                                }
                                                .clickable { selectedDay = dayStart }
                                                .padding(horizontal = 8.dp, vertical = 6.dp),
                                        ) {
                                            Text("$day", color = if (isToday) TL.rec else TL.paper,
                                                fontSize = 15.sp, fontWeight = FontWeight.Bold)
                                            Spacer(Modifier.height(4.dp))
                                            if (icon != null) {
                                                Image(painterResource(dayOutcomeDrawable(icon)), null,
                                                    Modifier.size(17.dp))
                                            } else {
                                                Box(Modifier.padding(vertical = 6.5.dp).size(4.dp)
                                                    .background(TL.hairline, CircleShape))
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
            TLEyebrow("누적 대시보드")
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
                    Text("총점", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text("$total", color = if (total >= 0) TL.jade else TL.rec,
                            fontSize = 36.sp, fontWeight = FontWeight.Black, maxLines = 1)
                        Text("점", color = TL.muted, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(start = 4.dp, bottom = 5.dp))
                    }
                }
                Spacer(Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                        MiniStat("총 상점", "$plus", TL.jade)
                        MiniStat("완주율", "$completeRate%", TL.jade)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                        // 벌점은 빨간색이 이미 '깎였다'를 말하므로 절대값으로 표기
                        MiniStat("총 벌점", "${kotlin.math.abs(minusSum)}", TL.rec)
                        MiniStat("노쇼율", "$noShowRate%", if (noShowRate > 0) TL.rec else TL.muted)
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
        selectedDay?.let { dayStart ->
            val end = dayStart + 86_400_000L
            val daySessions = finished.filter { it.anchorAt in dayStart until end }
                .sortedByDescending { it.anchorAt }
            item {
                TLEyebrow(if (dayStart == todayStart) "오늘의 기록" else "이 날의 기록")
            }
            if (daySessions.isEmpty()) {
                item { Text("기록 없음", color = TL.faint, fontSize = 13.sp) }
            }
            daySessions.forEach { s ->
                item {
                    SessionRow(s, events)
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
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
        successSessions.groupBy { it.tag }
            .mapValues { (_, list) -> list.sumOf { it.recordedSeconds } }
            .toList().sortedByDescending { it.second }
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
                    Text("연속달성", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                        maxLines = 1, softWrap = false)
                    Spacer(Modifier.width(5.dp))
                    Image(painterResource(com.singlemarks.angrymoti.R.drawable.stat_fire), null,
                        Modifier.size(15.dp))
                }
                Spacer(Modifier.height(5.dp))
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("${detail.first}", color = TL.jade, fontSize = 36.sp,
                        fontWeight = FontWeight.Black, maxLines = 1)
                    Text("일", color = TL.muted, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(start = 2.dp, bottom = 5.dp))
                }
                Spacer(Modifier.height(5.dp))
                // "총 N시간 n분을 기록했어요!" — 1시간 미만도 0시간이 아니라 분으로 보인다
                Row {
                    Text("총 ", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    hourMinuteParts(totalSeconds).forEachIndexed { i, (value, unit) ->
                        if (i > 0) Text(" ", fontSize = 13.sp)
                        Text(value, color = TL.jade, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Text(unit, color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text("을 기록했어요!", color = TL.muted, fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // 아이콘 배정: 최고기록 = 별(stat_average), 평균 일정 = 깃발(stat_record).
                // 에셋 파일명과 화면 배정이 어긋나 있으니 이름만 보고 되돌리지 말 것 (iOS 동일).
                SideStat("최고기록", com.singlemarks.angrymoti.R.drawable.stat_average, "$best", "일")
                SideStat("평균 일정", com.singlemarks.angrymoti.R.drawable.stat_record, averageLabel, "개")
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
        if (rest > 0) rows.add("그 외" to rest)
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
        Text("태그별 시간 분포", color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        Text("(시간 : 분)", color = TL.faint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
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
                        Text("총 ", color = TL.muted, fontSize = 14.sp, fontWeight = FontWeight.Black)
                        Text("%,d".format(totalSeconds / 60), color = TL.jade,
                            fontSize = 14.sp, fontWeight = FontWeight.Black, maxLines = 1)
                        Text("분", color = TL.muted, fontSize = 14.sp, fontWeight = FontWeight.Black)
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

/** 접힘: 성취 원·시작 시각·활동명·점수·화살표 / 펼침: 결과·강도·썸네일·사유·순수촬영시간 (iOS DayDetailView 1:1) */
@Composable
private fun SessionRow(s: FocusSession, events: List<com.singlemarks.angrymoti.data.ScoreEvent>) {
    val context = LocalContext.current
    var expanded by remember(s.id) { mutableStateOf(false) }
    val outcome = s.outcome
    val pts = outcome?.let { ScoreRules.points(it, s.intensity, s.targetSeconds / 60)?.second }
    val circleColor = when {
        outcome?.isSuccess == true -> TL.jade
        outcome?.isFailure == true -> TL.rec
        else -> TL.amber   // 긴급 종료·안전 종료
    }

    TLCard {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(vertical = 2.dp),
        ) {
            Box(Modifier.size(16.dp).background(circleColor, CircleShape)
                .border(3.dp, circleColor.copy(alpha = 0.35f), CircleShape))
            Spacer(Modifier.width(12.dp))
            Text(TLFormat.clock(s.anchorAt), color = TL.paper, fontSize = 14.sp,
                fontWeight = FontWeight.Bold, modifier = Modifier.width(52.dp))
            Text(s.activityName, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, modifier = Modifier.weight(1f))
            pts?.let {
                Text(TLFormat.scoreLabel(it), color = if (it >= 0) TL.jade else TL.rec,
                    fontSize = 14.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.width(8.dp))
            }
            androidx.compose.material3.Icon(
                if (expanded) AppIcon.ChevronUp else AppIcon.ChevronDown, null,
                tint = TL.faint, modifier = Modifier.size(15.dp))
        }

        if (expanded) {
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(outcome?.title ?: "", color = circleColor, fontSize = 12.sp, fontWeight = FontWeight.Bold)
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
                        Modifier.fillMaxWidth(0.4f).aspectRatio(3f / 4f).clip(TL.cornerS),
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                    Spacer(Modifier.height(8.dp))
                }
            }
            // 실패/긴급 사유 — 점수 원장의 note 우선, 없으면 세션의 긴급 사유 (iOS 1:1).
            // 세션 사유만 보면 알람 화면의 '일정 취소' 사유(원장에만 기록)가 안 보인다.
            val reason = events.firstOrNull { it.sessionID == s.id && !it.note.isNullOrEmpty() }?.note
                ?: s.emergencyReason
            reason?.let {
                Text("사유: $it", color = TL.amber, fontSize = 12.sp)
                Spacer(Modifier.height(4.dp))
            }
            Text("순수 촬영 ${TLFormat.durationLabel(s.recordedSeconds / 60)} / 목표 ${TLFormat.durationLabel(s.targetSeconds / 60)}",
                color = TL.muted, fontSize = 12.sp)
        }
    }
}
