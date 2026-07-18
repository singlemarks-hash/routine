package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.background
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.FocusSession
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.ui.theme.TL
import java.util.Calendar

/** 기록 캘린더 — 날짜 원 색은 그날 순점수 합(초록/빨강/앰버), 연속 달성일 대시보드 */
@Composable
fun CalendarScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    val owner = AccountStore.currentUserID
    val sessions by db.sessions().allFlow(owner).collectAsState(initial = emptyList())
    val events by db.scores().allFlow(owner).collectAsState(initial = emptyList())
    var month by remember { mutableStateOf(Calendar.getInstance()) }
    var selectedDay by remember { mutableStateOf<Long?>(null) }

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
            Row(Modifier.fillMaxWidth().padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("← 뒤로", color = TL.muted, fontSize = 15.sp,
                    modifier = Modifier.clickable(onClick = onBack).padding(4.dp))
                Spacer(Modifier.weight(1f))
                Text("기록", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.weight(1f))
                Spacer(Modifier.width(48.dp))
            }
        }
        item {
            TLCard {
                Row {
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("$streak", color = TL.jade, fontSize = 26.sp, fontWeight = FontWeight.Black)
                        Text("연속 달성일", color = TL.muted, fontSize = 12.sp)
                    }
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("${finished.count { it.outcome!!.isSuccess }}", color = TL.paper,
                            fontSize = 26.sp, fontWeight = FontWeight.Black)
                        Text("총 완주", color = TL.muted, fontSize = 12.sp)
                    }
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("${events.sumOf { it.points }}", color = TL.paper,
                            fontSize = 26.sp, fontWeight = FontWeight.Black)
                        Text("누적 총점", color = TL.muted, fontSize = 12.sp)
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
        }
        item {
            // 월 헤더
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("◀", color = TL.muted, modifier = Modifier.clickable {
                    month = (month.clone() as Calendar).apply { add(Calendar.MONTH, -1) }
                }.padding(8.dp))
                Spacer(Modifier.weight(1f))
                Text("${month.get(Calendar.YEAR)}년 ${month.get(Calendar.MONTH) + 1}월",
                    color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text("▶", color = TL.muted, modifier = Modifier.clickable {
                    month = (month.clone() as Calendar).apply { add(Calendar.MONTH, 1) }
                }.padding(8.dp))
            }
            Spacer(Modifier.height(8.dp))
            // 요일 헤더 + 날짜 그리드
            Row(Modifier.fillMaxWidth()) {
                listOf("일", "월", "화", "수", "목", "금", "토").forEach {
                    Text(it, color = TL.faint, fontSize = 12.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        modifier = Modifier.weight(1f))
                }
            }
            Spacer(Modifier.height(6.dp))
            val first = (month.clone() as Calendar).apply {
                set(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            val lead = first.get(Calendar.DAY_OF_WEEK) - 1
            val daysInMonth = month.getActualMaximum(Calendar.DAY_OF_MONTH)
            val cells = lead + daysInMonth
            val weeks = (cells + 6) / 7
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                repeat(weeks) { w ->
                    Row(Modifier.fillMaxWidth()) {
                        repeat(7) { d ->
                            val idx = w * 7 + d
                            val day = idx - lead + 1
                            Box(Modifier.weight(1f).height(44.dp), contentAlignment = Alignment.Center) {
                                if (day in 1..daysInMonth) {
                                    val dayStart = first.timeInMillis + (day - 1) * 86_400_000L
                                    val net = dayNet(dayStart)
                                    val bg = when {
                                        net == null -> TL.surface
                                        net > 0 -> TL.jade
                                        net < 0 -> TL.rec
                                        else -> TL.amber
                                    }
                                    Box(
                                        Modifier.size(38.dp).background(bg, CircleShape)
                                            .clickable { selectedDay = dayStart },
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Text("$day", fontSize = 13.sp, fontWeight = FontWeight.Bold,
                                            color = if (net == null) TL.muted else TL.ink)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
        selectedDay?.let { dayStart ->
            val end = dayStart + 86_400_000L
            val daySessions = finished.filter { it.anchorAt in dayStart until end }
                .sortedByDescending { it.anchorAt }
            item { TLEyebrow("이 날의 기록") }
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

@Composable
private fun SessionRow(s: FocusSession) {
    TLCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(s.activityName, color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                Text("${s.outcome?.title} · ${TLFormat.durationLabel(s.targetSeconds / 60)} · ${s.intensity.title}",
                    color = TL.muted, fontSize = 12.sp)
                s.emergencyReason?.let { Text("사유: $it", color = TL.faint, fontSize = 12.sp) }
            }
            val pts = s.outcome?.let { o ->
                ScoreRules.points(o, s.intensity, s.targetSeconds / 60)?.second
            }
            pts?.let {
                Text(TLFormat.scoreLabel(it), color = if (it >= 0) TL.jade else TL.rec,
                    fontSize = 16.sp, fontWeight = FontWeight.Black)
            }
        }
    }
}
