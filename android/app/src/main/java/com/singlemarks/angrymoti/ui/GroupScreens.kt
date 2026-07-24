package com.singlemarks.angrymoti.ui

import android.widget.Toast
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.models.GroupPolicy
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.TimePolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.GroupStore
import com.singlemarks.angrymoti.services.GroupStore.GroupRoom
import com.singlemarks.angrymoti.services.SubscriptionManager
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.launch
import java.util.Calendar

// MARK: 그룹 챌린지 탭 — iOS GroupTabView 1:1 (멤버십 전용, 게스트는 탭 자체가 숨겨짐)

private object GroupFormat {
    private val weekdayNames = listOf("", "일", "월", "화", "수", "목", "금", "토")

    // iOS: "매주 월 화 수" (공백 구분, '매일' 축약 없음) 1:1
    fun weekdays(days: List<Int>): String =
        "매주 " + days.sorted().joinToString(" ") { weekdayNames[it] }

    // iOS: "오후 7시" / "오전 9:30" (12시간 한국어) 1:1
    fun time(startMinute: Int): String {
        val h = startMinute / 60; val m = startMinute % 60
        val ampm = if (h >= 12) "오후" else "오전"
        val h12 = if (h % 12 == 0) 12 else h % 12
        return if (m == 0) "$ampm ${h12}시" else "$ampm $h12:${"%02d".format(m)}"
    }

    fun duration(minutes: Int): String = when {
        minutes % 60 == 0 -> "${minutes / 60}시간"
        minutes > 60 -> "${minutes / 60}시간 ${minutes % 60}분"
        else -> "${minutes}분"
    }

    // iOS: "M월 d일 (E)" 1:1
    fun day(millis: Long): String =
        java.text.SimpleDateFormat("M월 d일 (E)", java.util.Locale.KOREA).format(java.util.Date(millis))

    fun period(start: Long, end: Long): String = "${day(start)} ~ ${day(end)}"

    fun schedule(room: GroupRoom): String =
        "${weekdays(room.repeatWeekdays)} · ${time(room.startMinute)} · ${duration(room.durationMinutes)}"

    /** 시작일까지 남은 일수 라벨 — iOS dDay 1:1 (시작일=오늘이면 "오늘", 이후 "D-N") */
    fun dDay(startMillis: Long): String {
        val today = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val startDay = Calendar.getInstance().apply {
            timeInMillis = startMillis
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val days = ((startDay - today) / 86_400_000L).toInt()
        return if (days <= 0) "오늘" else "D-$days"
    }
}

private sealed class GroupNav {
    data object List : GroupNav()
    data object Create : GroupNav()
    data object Join : GroupNav()
    data class Detail(val roomId: String) : GroupNav()
    data object Paywall : GroupNav()
}

@Composable
fun GroupTab(openRoomId: String? = null, onRoomOpened: () -> Unit = {}) {
    val context = LocalContext.current
    val rooms by GroupStore.rooms.collectAsState()
    val cancelled by GroupStore.cancelledNotices.collectAsState()
    val disbanded by GroupStore.disbandedNotices.collectAsState()
    val refreshing by GroupStore.isRefreshing.collectAsState()
    val isPro by SubscriptionManager.isPro.collectAsState()
    var nav by remember { mutableStateOf<GroupNav>(GroupNav.List) }

    LaunchedEffect(Unit) { GroupStore.refresh(context) }

    // 외부(주간 일정 등)에서 특정 방으로 바로 진입 요청 — 방 목록에 로드되면 상세로 이동
    LaunchedEffect(openRoomId, rooms) {
        if (openRoomId != null && rooms.any { it.id == openRoomId }) {
            nav = GroupNav.Detail(openRoomId)
            onRoomOpened()
        }
    }

    // 기존 방은 구독이 끊겨도 계속 볼 수 있다 — 새 생성·참여만 잠금 (iOS 동일)
    val locked = !isPro

    // 뒤로가기: 그룹 내부 화면(생성/참여/상세/페이월)에서는 목록으로 복귀.
    // 목록에서는 여기서 가로채지 않아 HomeShell의 BackHandler(홈으로 복귀)로 넘어간다.
    androidx.activity.compose.BackHandler(enabled = nav != GroupNav.List) { nav = GroupNav.List }

    when (val n = nav) {
        GroupNav.Paywall -> { PaywallScreen(onBack = { nav = GroupNav.List }); return }
        GroupNav.Create -> { GroupCreateScreen(onDone = { nav = GroupNav.List }); return }
        GroupNav.Join -> { GroupJoinScreen(onDone = { nav = GroupNav.List }); return }
        is GroupNav.Detail -> {
            val room = rooms.firstOrNull { it.id == n.roomId }
            if (room == null) { nav = GroupNav.List } else {
                GroupRoomDetailScreen(room, onBack = { nav = GroupNav.List })
                return
            }
        }
        GroupNav.List -> {}
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp),
    ) {
        Spacer(Modifier.height(6.dp))
        // iOS header 1:1 — GROUP CHALLENGE eyebrow + 타이틀 + 부제
        Row(verticalAlignment = Alignment.CenterVertically) {
            TLEyebrow("GROUP CHALLENGE", color = TL.rec)
            Spacer(Modifier.weight(1f))
            if (refreshing) CircularProgressIndicator(
                modifier = Modifier.size(16.dp), color = TL.muted, strokeWidth = 2.dp)
        }
        Text("같이 하면 못 도망간다", color = TL.paper, fontSize = 24.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(6.dp))
        Text("초대코드로 모여 같은 일정으로 대결해요.\n그룹 점수는 0점부터, 개인 누적에도 그대로 쌓입니다.",
            color = TL.muted, fontSize = 13.sp, lineHeight = 19.sp)
        Spacer(Modifier.height(16.dp))

        // 취소·해체 안내 카드
        (cancelled + disbanded).forEach { notice ->
            TLCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.Icon(AppIcon.Info, null,
                        tint = TL.amber, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(notice, color = TL.paper, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    Text("확인", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.clickable { GroupStore.clearNotices() }.padding(4.dp))
                }
            }
            Spacer(Modifier.height(10.dp))
        }

        if (locked && rooms.isEmpty()) {
            // 멤버십 잠금 패널 (iOS lockedPanel 1:1)
            Spacer(Modifier.height(40.dp))
            Column(
                Modifier.fillMaxWidth().background(TL.surface, TL.cornerL)
                    .border(1.dp, TL.hairline, TL.cornerL).padding(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.size(64.dp).background(TL.raised, CircleShape),
                    contentAlignment = Alignment.Center) {
                    androidx.compose.material3.Icon(AppIcon.Lock, null,
                        tint = TL.amber, modifier = Modifier.size(26.dp))
                }
                Spacer(Modifier.height(16.dp))
                Text("그룹 챌린지는 멤버십 전용", color = TL.paper,
                    fontSize = 19.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(8.dp))
                Text("초대코드로 지인들과 모여 같은 일정으로 대결해요.\n노쇼도 완주도 전부 랭킹에 반영됩니다.",
                    color = TL.muted, fontSize = 13.sp, textAlign = TextAlign.Center, lineHeight = 20.sp)
                Spacer(Modifier.height(20.dp))
                TLPrimaryButton("멤버십 구독하고 시작하기", tint = TL.jade) { nav = GroupNav.Paywall }
            }
        } else {
            // iOS 1:1 — 버튼 세로 스택 (그룹방 만들기 rec / 초대코드로 참여하기 ghost)
            TLPrimaryButton("그룹방 만들기") {
                if (locked) nav = GroupNav.Paywall else nav = GroupNav.Create
            }
            Spacer(Modifier.height(10.dp))
            TLGhostButton("초대코드로 참여하기") {
                if (locked) nav = GroupNav.Paywall else nav = GroupNav.Join
            }
            Spacer(Modifier.height(22.dp))

            // '내 그룹' 섹션 헤더 (iOS와 동일하게 목록을 별도로 묶는다)
            Text("내 그룹", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.height(12.dp))

            if (rooms.isEmpty()) {
                TLCard {
                    Text("참여 중인 그룹이 없습니다. 방을 만들어 초대코드를 공유하거나, 받은 코드로 참여해 보세요.",
                        color = TL.muted, fontSize = 13.sp, lineHeight = 20.sp)
                }
            } else {
                rooms.forEach { room ->
                    GroupRoomCard(room) { nav = GroupNav.Detail(room.id) }
                    Spacer(Modifier.height(10.dp))
                }
            }
        }
        Spacer(Modifier.height(110.dp))   // 하단 토글에 안 가리게
    }
}

@Composable
private fun GroupRoomCard(room: GroupRoom, onClick: () -> Unit) {
    // iOS statusChip 1:1 — 종료(faint) / 진행 중(jade) / 시작 D-N(amber), 테두리 캡슐
    val (statusLabel, statusColor) = when {
        room.isFinished -> "종료" to TL.faint
        room.hasStarted -> "진행 중" to TL.jade
        else -> "${GroupFormat.dDay(room.startDate)} 시작" to TL.amber
    }
    Column(
        Modifier.fillMaxWidth().background(TL.surface, TL.cornerL)
            .border(1.dp, TL.hairline, TL.cornerL)
            .clickable(onClick = onClick).padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(room.name, color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Black,
                maxLines = 1)
            if (room.isHostMine) {
                Spacer(Modifier.width(6.dp))
                Text("★", color = TL.amber, fontSize = 13.sp)   // 방장 표시
            }
            Spacer(Modifier.weight(1f))
            Text(statusLabel, color = statusColor,
                fontSize = 12.sp, fontWeight = FontWeight.Black,
                modifier = Modifier
                    .border(1.dp, statusColor.copy(alpha = 0.5f), CircleShape)
                    .padding(horizontal = 10.dp, vertical = 4.dp))
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.Icon(AppIcon.Users, null,
                tint = TL.muted, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(5.dp))
            Text("${room.memberCount}명", color = TL.muted, fontSize = 13.sp)
            Text("  ·  ", color = TL.muted, fontSize = 13.sp)
            Text(GroupFormat.schedule(room), color = TL.muted, fontSize = 13.sp, maxLines = 1)
        }
    }
}

// MARK: 초대코드 카드 — 탭하면 복사

@Composable
private fun InviteCodeCard(code: String) {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    Column(
        Modifier.fillMaxWidth().background(TL.raised, TL.cornerL)
            .border(1.dp, TL.hairline, TL.cornerL)
            .clickable {
                clipboard.setText(AnnotatedString(code))
                Toast.makeText(context, "초대코드를 복사했어요", Toast.LENGTH_SHORT).show()
            }
            .padding(vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        TLEyebrow("초대코드")
        Spacer(Modifier.height(8.dp))
        Text(code.toCharArray().joinToString("  "), color = TL.paper,
            fontSize = 30.sp, fontWeight = FontWeight.Black, letterSpacing = 2.sp)
        Spacer(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.Icon(AppIcon.Copy, null,
                tint = TL.muted, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(5.dp))
            Text("탭해서 복사", color = TL.muted, fontSize = 12.sp)
        }
    }
}

// MARK: 방 만들기 — iOS GroupCreateView 1:1

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GroupCreateScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var name by remember { mutableStateOf("") }
    var nickname by remember { mutableStateOf("") }
    var intensity by remember { mutableStateOf(Intensity.SPICY) }
    var startMinute by remember { mutableStateOf(19 * 60) }               // 기본 19:00 (iOS 통일)
    var durationMinutes by remember { mutableStateOf(30) }                // 기본 30분 (iOS 통일)
    var repeatDays by remember { mutableStateOf(setOf(1, 2, 3, 4, 5, 6, 7)) }   // 기본 매일 (iOS 통일)
    val tomorrow = remember {
        Calendar.getInstance().apply {
            add(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }
    var startDay by remember { mutableStateOf(tomorrow) }
    var endDay by remember { mutableStateOf(tomorrow + 27 * 86_400_000L) }   // 28일 창 (iOS today+28 통일)
    var showTimePicker by remember { mutableStateOf(false) }
    var showDurationMenu by remember { mutableStateOf(false) }
    var pickingDate by remember { mutableStateOf<String?>(null) }   // "start" | "end"
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var created by remember { mutableStateOf<GroupRoom?>(null) }

    val timeState = rememberTimePickerState(
        initialHour = startMinute / 60, initialMinute = startMinute % 60, is24Hour = false)

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TLPillButton("닫기", tint = TL.paper, onClick = onDone)
            Spacer(Modifier.weight(1f))
            Text("그룹방 만들기", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f))
            TLPillButton("만들기", tint = TL.rec,
                enabled = !busy && created == null && name.isNotBlank()
                    && nickname.isNotBlank() && repeatDays.isNotEmpty()) {
                error = null; busy = true
                val chosenStartMinute = timeState.hour * 60 + timeState.minute
                val startMoment = startDay + chosenStartMinute * 60_000L   // 실제 시작 순간
                scope.launch {
                    try {
                        val days = ((endDay - startDay) / 86_400_000L).toInt() + 1
                        if (endDay < startDay) throw GroupStore.GroupException("종료일이 시작일보다 빠를 수 없어요.")
                        if (days > GroupPolicy.MAX_DURATION_DAYS)
                            throw GroupStore.GroupException("기간은 최대 ${GroupPolicy.MAX_DURATION_DAYS}일(3개월)까지 가능해요.")
                        // 시작은 지금부터 최소 1시간 뒤 (참여자가 10분 전 알람을 받을 수 있게 여유를 둔다)
                        if (startMoment < System.currentTimeMillis() + GroupPolicy.MIN_START_LEAD_MINUTES * 60_000L)
                            throw GroupStore.GroupException(
                                "시작은 지금부터 최소 ${GroupPolicy.MIN_START_LEAD_MINUTES / 60}시간 이후로 설정해주세요.")
                        GroupStore.checkSlotAvailable(context)
                        GroupStore.checkScheduleConflict(context, chosenStartMinute, durationMinutes,
                            repeatDays.toList(), startDay, endDay + 86_400_000L - 1)
                        created = GroupStore.createRoom(
                            context, name.trim(), nickname.trim(), intensity,
                            chosenStartMinute, durationMinutes, repeatDays.toList().sorted(),
                            startMoment, endDay + 86_400_000L - 1,   // startDate = 실제 시작 순간(iOS 통일)
                        )
                    } catch (e: Exception) {
                        error = e.message ?: "방 생성에 실패했어요."
                    } finally { busy = false }
                }
            }
        }

        val createdRoom = created
        if (createdRoom != null) {
            // 생성 완료 패널 — 초대코드 공유
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(32.dp))
                Text("방이 만들어졌어요!", color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(8.dp))
                Text("아래 초대코드를 지인들에게 공유하세요.\n시작 시각에 ${GroupPolicy.MIN_MEMBERS_TO_START}명 이상이면 대결이 시작됩니다.",
                    color = TL.muted, fontSize = 14.sp, textAlign = TextAlign.Center, lineHeight = 21.sp)
                Spacer(Modifier.height(20.dp))
                InviteCodeCard(createdRoom.code)
                Spacer(Modifier.height(20.dp))
                TLPrimaryButton("완료", tint = TL.jade) { onDone() }
            }
        } else Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp),
        ) {
            error?.let {
                Text(it, color = TL.rec, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 10.dp))
            }

            GroupField(name, { name = it }, "방 이름 (예: 아침 공부방)")
            Spacer(Modifier.height(10.dp))
            GroupField(nickname, { nickname = it.take(GroupPolicy.NICKNAME_MAX_LENGTH) },
                "내 닉네임 (최대 ${GroupPolicy.NICKNAME_MAX_LENGTH}자)")
            Spacer(Modifier.height(14.dp))

            TLCard {
                TLEyebrow("강도")
                Spacer(Modifier.height(8.dp))
                Row {
                    Intensity.entries.forEach { level ->
                        val selected = intensity == level
                        Text("${level.emoji} ${level.title}",
                            color = if (selected) TL.ink else TL.paper,
                            fontSize = 14.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .background(if (selected) TL.paper else TL.raised, CircleShape)
                                .clickable { intensity = level }
                                .padding(horizontal = 16.dp, vertical = 10.dp))
                        Spacer(Modifier.width(8.dp))
                    }
                }
                Spacer(Modifier.height(6.dp))
                Text(intensity.subtitle, color = TL.faint, fontSize = 12.sp)
            }
            Spacer(Modifier.height(10.dp))

            TLCard {
                TLEyebrow("일정 — 전원에게 동일하게 적용")
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("시작 시각", color = TL.paper, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Text(GroupFormat.time(timeState.hour * 60 + timeState.minute),
                        color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Black,
                        modifier = Modifier.background(TL.raised, CircleShape)
                            .clickable { showTimePicker = !showTimePicker }
                            .padding(horizontal = 14.dp, vertical = 8.dp))
                }
                if (showTimePicker) {
                    Spacer(Modifier.height(8.dp))
                    TimePicker(state = timeState)
                }
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("1회 길이", color = TL.paper, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Box {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.background(TL.raised, CircleShape)
                                .clickable { showDurationMenu = true }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        ) {
                            Text(GroupFormat.duration(durationMinutes), color = TL.paper,
                                fontSize = 15.sp, fontWeight = FontWeight.Black)
                            Spacer(Modifier.width(6.dp))
                            androidx.compose.material3.Icon(AppIcon.ChevronsUpDown, null,
                                tint = TL.muted, modifier = Modifier.size(14.dp))
                        }
                        androidx.compose.material3.DropdownMenu(
                            expanded = showDurationMenu,
                            onDismissRequest = { showDurationMenu = false },
                        ) {
                            TimePolicy.durationOptionsMinutes.forEach { m ->
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text(GroupFormat.duration(m)) },
                                    onClick = { durationMinutes = m; showDurationMenu = false })
                            }
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                Text("반복 요일", color = TL.paper, fontSize = 15.sp)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(1 to "일", 2 to "월", 3 to "화", 4 to "수", 5 to "목", 6 to "금", 7 to "토")
                        .forEach { (day, label) ->
                            val selected = day in repeatDays
                            Box(
                                Modifier.size(38.dp)
                                    .background(if (selected) TL.paper else TL.raised, CircleShape)
                                    .clickable {
                                        repeatDays = if (selected) repeatDays - day else repeatDays + day
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(label, color = if (selected) TL.ink else TL.muted,
                                    fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                }
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("기간", color = TL.paper, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Text(GroupFormat.day(startDay), color = TL.paper, fontSize = 14.sp,
                        fontWeight = FontWeight.Black,
                        modifier = Modifier.background(TL.raised, CircleShape)
                            .clickable { pickingDate = "start" }
                            .padding(horizontal = 12.dp, vertical = 7.dp))
                    Text("  ~  ", color = TL.muted, fontSize = 14.sp)
                    Text(GroupFormat.day(endDay), color = TL.paper, fontSize = 14.sp,
                        fontWeight = FontWeight.Black,
                        modifier = Modifier.background(TL.raised, CircleShape)
                            .clickable { pickingDate = "end" }
                            .padding(horizontal = 12.dp, vertical = 7.dp))
                }
                Spacer(Modifier.height(6.dp))
                Text("내일부터 시작 가능 · 최대 ${GroupPolicy.MAX_DURATION_DAYS}일(3개월) · " +
                    "시작 시각에 ${GroupPolicy.MIN_MEMBERS_TO_START}명 미만이면 자동 취소",
                    color = TL.faint, fontSize = 12.sp, lineHeight = 18.sp)
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (pickingDate != null) {
        val initial = if (pickingDate == "start") startDay else endDay
        val dateState = androidx.compose.material3.rememberDatePickerState(
            initialSelectedDateMillis = initial)
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { pickingDate = null },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    dateState.selectedDateMillis?.let { utc ->
                        // DatePicker는 UTC 자정 기준 — 로컬 자정으로 변환해 저장
                        val u = Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
                            .apply { timeInMillis = utc }
                        val local = Calendar.getInstance().apply {
                            set(u.get(Calendar.YEAR), u.get(Calendar.MONTH),
                                u.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
                            set(Calendar.MILLISECOND, 0)
                        }.timeInMillis
                        if (pickingDate == "start") startDay = local else endDay = local
                    }
                    pickingDate = null
                }) { Text("확인", color = TL.rec, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { pickingDate = null }) {
                    Text("취소", color = TL.muted)
                }
            },
        ) { androidx.compose.material3.DatePicker(state = dateState) }
    }
}

// MARK: 초대코드 참여 — iOS GroupJoinView 1:1

@Composable
private fun GroupJoinScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var nickname by remember { mutableStateOf("") }
    var preview by remember { mutableStateOf<GroupRoom?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var joined by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TLPillButton("닫기", tint = TL.paper, onClick = onDone)
            Spacer(Modifier.weight(1f))
            Text("초대코드로 참여", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(52.dp))
        }

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp),
        ) {
            error?.let {
                Text(it, color = TL.rec, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 10.dp))
            }

            val room = preview
            if (joined) {
                Spacer(Modifier.height(40.dp))
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.size(64.dp).background(TL.jade, CircleShape),
                        contentAlignment = Alignment.Center) {
                        androidx.compose.material3.Icon(AppIcon.Check, null,
                            tint = TL.ink, modifier = Modifier.size(28.dp))
                    }
                    Spacer(Modifier.height(16.dp))
                    Text("참여 완료!", color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.height(8.dp))
                    Text("그룹 일정이 활동 목록에 추가됐어요.\n시작일부터 알람이 울립니다.",
                        color = TL.muted, fontSize = 14.sp, textAlign = TextAlign.Center, lineHeight = 21.sp)
                    Spacer(Modifier.height(24.dp))
                    TLPrimaryButton("확인", tint = TL.jade) { onDone() }
                }
            } else if (room == null) {
                GroupField(code, { code = it.uppercase().take(GroupPolicy.CODE_LENGTH) },
                    "초대코드 ${GroupPolicy.CODE_LENGTH}자리")
                Spacer(Modifier.height(14.dp))
                TLPrimaryButton("방 찾기",
                    enabled = !busy && code.length == GroupPolicy.CODE_LENGTH) {
                    error = null; busy = true
                    scope.launch {
                        try { preview = GroupStore.lookup(code) }
                        catch (e: Exception) { error = e.message }
                        finally { busy = false }
                    }
                }
            } else {
                TLCard(raised = true) {
                    Text(room.name, color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.height(8.dp))
                    Text(GroupFormat.schedule(room), color = TL.paper, fontSize = 14.sp)
                    Spacer(Modifier.height(4.dp))
                    Text(GroupFormat.period(room.startDate, room.endDate), color = TL.muted, fontSize = 13.sp)
                    Spacer(Modifier.height(4.dp))
                    Text("${room.intensity.emoji} ${room.intensity.title} · " +
                        "현재 ${room.memberCount}/${GroupPolicy.MAX_MEMBERS}명",
                        color = TL.muted, fontSize = 13.sp)
                }
                Spacer(Modifier.height(12.dp))
                GroupField(nickname, { nickname = it.take(GroupPolicy.NICKNAME_MAX_LENGTH) },
                    "이 방에서 쓸 닉네임 (최대 ${GroupPolicy.NICKNAME_MAX_LENGTH}자)")
                Spacer(Modifier.height(14.dp))
                TLPrimaryButton(if (busy) "참여 중…" else "이 방에 참여하기",
                    enabled = !busy && nickname.isNotBlank()) {
                    error = null; busy = true
                    scope.launch {
                        try {
                            GroupStore.checkSlotAvailable(context)
                            GroupStore.checkScheduleConflict(context, room)
                            GroupStore.join(context, room, nickname.trim())
                            joined = true
                        } catch (e: Exception) {
                            error = e.message
                        } finally { busy = false }
                    }
                }
                Spacer(Modifier.height(8.dp))
                TLGhostButton("다른 코드 입력", tint = TL.muted) {
                    preview = null; nickname = ""; error = null
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

// MARK: 방 상세 — 대기실 / 랭킹 / 최종 결과 (iOS GroupRoomDetailView 1:1)

@Composable
private fun GroupRoomDetailScreen(room: GroupRoom, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var members by remember { mutableStateOf(listOf<GroupStore.GroupMember>()) }
    var confirmAction by remember { mutableStateOf<String?>(null) }   // disband | leave | quit
    val myUid = AccountStore.currentUserID

    LaunchedEffect(room.id) { members = GroupStore.members(room.id) }

    val waiting = room.status == "scheduled" && !room.hasStarted
    val finished = room.isFinished

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TLCircleBack(onClick = onBack)
            Spacer(Modifier.weight(1f))
            Text(room.name, color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(45.dp))
        }

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp),
        ) {
            // 정보 카드 — 이름 + 방장 별 + 일정 + 기간·강도·인원 + D-day (iOS infoCard 1:1)
            TLCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(room.name, color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                    if (room.isHostMine) {
                        Spacer(Modifier.width(6.dp))
                        Text("★", color = TL.amber, fontSize = 14.sp)
                    }
                }
                Spacer(Modifier.height(6.dp))
                Text(GroupFormat.schedule(room), color = TL.muted, fontSize = 13.sp)
                Spacer(Modifier.height(2.dp))
                Text("${GroupFormat.period(room.startDate, room.endDate)} · " +
                    "${room.intensity.emoji} ${room.intensity.title} · ${room.memberCount}명",
                    color = TL.muted, fontSize = 13.sp)
                if (!room.hasStarted) {
                    Spacer(Modifier.height(4.dp))
                    Text("시작까지 ${GroupFormat.dDay(room.startDate)} — 시작 ${GroupPolicy.JOIN_CUTOFF_MINUTES}분 전까지만 참여할 수 있어요.",
                        color = TL.amber, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.height(16.dp))

            when {
                waiting -> {
                    // 초대코드는 방장에게만 (iOS 1:1)
                    if (room.isHostMine) {
                        InviteCodeCard(room.code)
                        Spacer(Modifier.height(6.dp))
                        Text("코드는 방장에게만 보여요. 시작 전까지 공유해 참여자를 모으세요.",
                            color = TL.faint, fontSize = 12.sp)
                        Spacer(Modifier.height(16.dp))
                    }
                    TLEyebrow("참여자 ${members.size}/${GroupPolicy.MAX_MEMBERS}")
                    Spacer(Modifier.height(8.dp))
                    TLCard {
                        val sorted = members.sortedBy { it.joinedAt }
                        sorted.forEachIndexed { index, m ->
                            Row(Modifier.padding(vertical = 9.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Text(m.nickname, color = TL.paper, fontSize = 15.sp,
                                    fontWeight = FontWeight.SemiBold)
                                if (m.id == room.hostUID) {
                                    Spacer(Modifier.width(6.dp))
                                    Text("★", color = TL.amber, fontSize = 12.sp)
                                }
                                if (m.id == myUid) {
                                    Spacer(Modifier.width(6.dp))
                                    Text("나", color = TL.ink, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                                        modifier = Modifier.background(TL.jade, CircleShape)
                                            .padding(horizontal = 7.dp, vertical = 2.dp))
                                }
                            }
                            if (index != sorted.lastIndex) {
                                androidx.compose.material3.HorizontalDivider(
                                    color = TL.hairline.copy(alpha = 0.5f))
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text("시작 시각에 ${GroupPolicy.MIN_MEMBERS_TO_START}명 미만이면 방이 자동 삭제됩니다.",
                        color = TL.faint, fontSize = 12.sp)
                    Spacer(Modifier.height(16.dp))
                    if (room.isHostMine) {
                        TLGhostButton("방 해체하기", tint = TL.rec) { confirmAction = "disband" }
                    } else {
                        TLGhostButton("방 나가기 (시작 전 자유 탈퇴)", tint = TL.muted) { confirmAction = "leave" }
                    }
                }
                else -> {
                    // 진행 중 / 종료 — 랭킹
                    TLCard(raised = true) {
                        TLEyebrow(if (finished) "최종 결과" else "실시간 랭킹")
                        Spacer(Modifier.height(8.dp))
                        val ranked = GroupStore.ranked(members)
                        val display = if (ranked.size > 7) {
                            val top = ranked.take(5)
                            val mine = ranked.filter { it.second.id == myUid && it.second !in top.map { t -> t.second } }
                            top + mine
                        } else ranked
                        display.forEachIndexed { index, (rank, m) ->
                            if (ranked.size > 7 && index == 5) {
                                Text("⋯", color = TL.faint, fontSize = 14.sp,
                                    modifier = Modifier.padding(vertical = 2.dp))
                            }
                            Row(Modifier.padding(vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    when (rank) {
                                        1 -> "🥇"; 2 -> "🥈"; 3 -> "🥉"; else -> "$rank"
                                    },
                                    color = TL.muted, fontSize = 15.sp, fontWeight = FontWeight.Black,
                                    modifier = Modifier.width(34.dp))
                                Text(
                                    m.nickname + if (m.id == myUid) " (나)" else "",
                                    color = if (m.quit) TL.faint else TL.paper, fontSize = 15.sp,
                                    fontWeight = if (m.id == myUid) FontWeight.Black else FontWeight.Normal,
                                    modifier = Modifier.weight(1f))
                                if (m.quit) {
                                    Text("포기", color = TL.faint, fontSize = 11.sp,
                                        modifier = Modifier.padding(end = 8.dp))
                                }
                                Text(TLFormat.scoreLabel(m.score),
                                    color = if (m.score >= 0) TL.jade else TL.rec,
                                    fontSize = 15.sp, fontWeight = FontWeight.Black)
                            }
                        }
                        if (members.isEmpty()) {
                            Text("불러오는 중…", color = TL.faint, fontSize = 13.sp)
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    if (finished) {
                        TLGhostButton("방 나가기 — 내 목록에서 제거", tint = TL.muted) {
                            scope.launch { GroupStore.hideFinishedRoom(room); onBack() }
                        }
                        Text("결과는 종료 후 ${GroupPolicy.RESULT_RETENTION_DAYS}일까지 보관됩니다.",
                            color = TL.faint, fontSize = 12.sp,
                            modifier = Modifier.padding(top = 6.dp))
                    } else {
                        val meQuit = members.firstOrNull { it.id == myUid }?.quit == true
                        if (!meQuit) {
                            TLGhostButton("중도 포기 (${ScoreRules.GROUP_QUIT_PENALTY}점 벌점)",
                                tint = TL.rec) { confirmAction = "quit" }
                        }
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    confirmAction?.let { action ->
        val (title, desc, button) = when (action) {
            "disband" -> Triple("방을 해체할까요?",
                "참여자들의 그룹 일정도 함께 사라집니다. 되돌릴 수 없어요.", "해체하기")
            "leave" -> Triple("방을 나갈까요?",
                "시작 전에는 벌점 없이 자유롭게 나갈 수 있어요.", "나가기")
            else -> Triple("정말 중도 포기할까요?",
                "${ScoreRules.GROUP_QUIT_PENALTY}점 벌점이 그룹 점수와 개인 점수에 모두 기록되고, 되돌릴 수 없어요.", "포기하기")
        }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmAction = null },
            containerColor = TL.surface,
            title = { Text(title, color = TL.paper, fontWeight = FontWeight.Black) },
            text = { Text(desc, color = TL.muted) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirmAction = null
                    scope.launch {
                        when (action) {
                            "disband" -> GroupStore.disband(context, room)
                            "leave" -> GroupStore.leaveBeforeStart(context, room)
                            else -> GroupStore.quitAfterStart(context, room)
                        }
                        onBack()
                    }
                }) { Text(button, color = TL.rec, fontWeight = FontWeight.Black) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirmAction = null }) {
                    Text("취소", color = TL.muted)
                }
            },
        )
    }
}

/** 큰 서피스 입력 필드 (ReservationEdit.TLField와 동일 룩) */
@Composable
private fun GroupField(value: String, onChange: (String) -> Unit, placeholder: String) {
    OutlinedTextField(
        value, onChange, modifier = Modifier.fillMaxWidth(), singleLine = true,
        placeholder = { Text(placeholder, color = TL.faint, fontSize = 16.sp) },
        shape = TL.cornerM,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = TL.surface, unfocusedContainerColor = TL.surface,
            focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
            focusedBorderColor = TL.hairline, unfocusedBorderColor = Color.Transparent,
            cursorColor = TL.rec),
    )
}
