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
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.FocusSession
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.ui.theme.TL
import java.io.File
import java.util.Calendar

/** 기록 캘린더 — 날짜 원 색은 그날 순점수 합(초록/빨강/앰버), 연속 달성일 대시보드 */
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
    val streak = SlotPolicy.currentStreak(
        finished.map { Triple(it.anchorAt, it.outcome!!.isSuccess, it.outcome!!.isFailure) })

    fun dayNet(dayStart: Long): Int? {
        val end = dayStart + 86_400_000L
        val ids = finished.filter { it.anchorAt in dayStart until end }.map { it.id }.toSet()
        if (ids.isEmpty()) return null
        return events.filter { it.sessionID in ids }.sumOf { it.points }
    }

    LazyColumn(Modifier.fillMaxSize().background(TL.ink).padding(horizontal = 20.dp)) {
        item {
            Box(Modifier.padding(top = 14.dp)) { TLScreenHeader("기록", onBack = onBack) }
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
                                        val net = dayNet(dayStart)
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
                                            // 기록 마커: 없음=흐린 점 / 순+=옥 점 / 순-=빨간 링 / 0=앰버 점
                                            when {
                                                net == null -> Box(Modifier.size(4.dp)
                                                    .background(TL.hairline, CircleShape))
                                                net < 0 -> Box(Modifier.size(12.dp)
                                                    .border(2.5.dp, TL.rec, CircleShape))
                                                net > 0 -> Box(Modifier.size(8.dp)
                                                    .background(TL.jade, CircleShape))
                                                else -> Box(Modifier.size(8.dp)
                                                    .background(TL.amber, CircleShape))
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
            // 누적 대시보드 — 6타일 그리드 (iOS 1:1)
            TLEyebrow("누적 대시보드")
            val total = events.sumOf { it.points }
            val done = finished.size
            val successes = finished.count { it.outcome!!.isSuccess }
            val noShows = finished.count { it.outcome == com.singlemarks.angrymoti.models.SessionOutcome.NO_SHOW }
            val plus = events.filter { it.points > 0 }.sumOf { it.points }
            val minusSum = events.filter { it.points < 0 }.sumOf { it.points }
            val completeRate = if (done > 0) successes * 100 / done else 0
            val noShowRate = if (done > 0) noShows * 100 / done else 0
            @Composable fun StatTile(value: String, label: String, color: androidx.compose.ui.graphics.Color,
                                     modifier: Modifier) {
                Column(modifier.background(TL.surface, TL.cornerM).padding(14.dp)) {
                    Text(value, color = color, fontSize = 24.sp, fontWeight = FontWeight.Black)
                    Text(label, color = TL.muted, fontSize = 12.sp)
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    StatTile("$total", "총점", if (total >= 0) TL.jade else TL.rec, Modifier.weight(1f))
                    StatTile("${streak}일", "연속 달성일", TL.paper, Modifier.weight(1f))
                    StatTile("$completeRate%", "완주율", TL.jade, Modifier.weight(1f))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    StatTile("$noShowRate%", "노쇼율", if (noShowRate > 0) TL.rec else TL.paper, Modifier.weight(1f))
                    StatTile("+$plus", "총 상점", TL.jade, Modifier.weight(1f))
                    StatTile("$minusSum", "총 벌점", if (minusSum < 0) TL.rec else TL.paper, Modifier.weight(1f))
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
                    SessionRow(s)
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

/** 접힘: 성취 원·시작 시각·활동명·점수·화살표 / 펼침: 결과·강도·썸네일·사유·순수촬영시간 (iOS DayDetailView 1:1) */
@Composable
private fun SessionRow(s: FocusSession) {
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
                val thumb = remember(name) {
                    runCatching {
                        android.graphics.BitmapFactory.decodeFile(
                            File(CameraRecorder.sessionDir(context), name).absolutePath)
                    }.getOrNull()
                }
                thumb?.let {
                    Image(it.asImageBitmap(), null,
                        Modifier.fillMaxWidth(0.4f).aspectRatio(3f / 4f).clip(TL.cornerS),
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                    Spacer(Modifier.height(8.dp))
                }
            }
            s.emergencyReason?.let {
                Text("사유: $it", color = TL.amber, fontSize = 12.sp)
                Spacer(Modifier.height(4.dp))
            }
            Text("순수 촬영 ${TLFormat.durationLabel(s.recordedSeconds / 60)} / 목표 ${TLFormat.durationLabel(s.targetSeconds / 60)}",
                color = TL.muted, fontSize = 12.sp)
        }
    }
}
