package com.singlemarks.angrymoti.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.R
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.launch

/**
 * 첫 실행 흐름: 1. 촬영하기 → 2. 기록관리 (로그인보다 먼저, 설명을 먼저 보여줘 로그인 장벽을
 * 낮춘다) → 로그인 → 3. 권한 설정 → 홈. (iOS OnboardingFlow.swift 1:1)
 * 강도 선택 단계는 폐기 — 강도는 활동별 설정으로 옮겨졌다.
 */

/** 로그인 이전, 기기 최초 1회만 보여주는 인트로 2페이지. 스와이프로 앞뒤 이동 가능. */
@Composable
fun IntroFlow(onFinish: () -> Unit) {
    val pagerState = rememberPagerState(pageCount = { 2 })
    val scope = rememberCoroutineScope()

    Box(Modifier.fillMaxSize().background(TL.ink)) {
        // 로그인 화면과 같은 계열의 레드 글로우 — 하단에서 위로 번지는 방향.
        // 기본 startY(0=위)~endY(무한대=아래)를 그대로 두고, 진한 색을 1.0(아래)에 둔다.
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.3f to Color.Transparent,
                    0.65f to TL.rec.copy(alpha = 0.10f),
                    1f to TL.rec.copy(alpha = 0.28f),
                )
            )
        )
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            when (page) {
                0 -> ShootStep { scope.launch { pagerState.animateScrollToPage(1) } }
                else -> RecordStep(
                    onBack = { scope.launch { pagerState.animateScrollToPage(0) } },
                    next = onFinish,
                )
            }
        }
    }
}

/** 로그인 이후, 홈 진입 전 권한 설정 1페이지. */
@Composable
fun OnboardingFlow() {
    PermissionStep(onFinish = { com.singlemarks.angrymoti.AppState.completeOnboarding() })
}

// MARK: - 1. 촬영하기

@Composable
private fun ShootStep(next: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
        Spacer(Modifier.height(110.dp))
        TLEyebrow("촬영하기")
        // 강제 줄바꿈(\n) 대신 자연 줄바꿈 — 갤럭시 노트20처럼 디스플레이 크기 설정이
        // 커서 유효 폭이 좁은 기기에서 \n 뒤 문구가 통째로 밀려 "없는"처럼 짧은 단어만
        // 홀로 한 줄을 차지하는 문제가 있었다. 공백으로 두면 기기 폭에 맞게 통째로 흐른다.
        Text("예약한 시각에 알람이 울리면 바로 타임랩스를 촬영하세요",
            color = TL.paper, fontSize = 26.sp, fontWeight = FontWeight.Black, lineHeight = 34.sp)
        Spacer(Modifier.height(10.dp))
        Text("내가 지정한 시간만큼 몰입 타이머가 시작돼요\n끝까지 완주하면 상점, 그만두면 벌점이 쌓여요",
            color = TL.muted, fontSize = 15.sp, lineHeight = 21.sp)

        Spacer(Modifier.weight(1f))

        // 책상에서 공부하는 모티 — 우측 정렬 (studying_moti, 사용자가 제공한 벡터 에셋).
        // 421x421 정사각 뷰포트를 그대로 쓰되, moti_smile과 같은 크기로 맞춘다.
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Image(painterResource(R.drawable.studying_moti), null,
                modifier = Modifier.size(170.dp))
        }

        Spacer(Modifier.weight(1f))

        TLPrimaryButton("다음", onClick = next)
        Spacer(Modifier.height(20.dp))
    }
}

// MARK: - 2. 기록관리

@Composable
private fun RecordStep(onBack: () -> Unit, next: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
        Spacer(Modifier.height(60.dp))
        Box(Modifier.clickable(onClick = onBack).padding(8.dp)) {
            androidx.compose.material3.Icon(AppIcon.ChevronLeft, contentDescription = "이전",
                tint = TL.muted, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.height(22.dp))
        TLEyebrow("기록관리")
        // 강제 줄바꿈(\n) 대신 자연 줄바꿈 — 위 ShootStep과 같은 이유(갤럭시 노트20 실기기
        // 리포트에서 "없는"이 단독 줄로 떨어지는 문제 확인됨).
        Text("의지가 아닌, 실행할 수 밖에 없는 환경을 만들어요",
            color = TL.paper, fontSize = 26.sp, fontWeight = FontWeight.Black, lineHeight = 34.sp)
        Spacer(Modifier.height(10.dp))
        Text("목표달성을 위한 나의 몰입을 기록해요\n모티가 강력한 실행환경을 만들어 줄 거에요",
            color = TL.muted, fontSize = 15.sp, lineHeight = 21.sp)

        Spacer(Modifier.weight(1f))

        StreakCardMock()

        Spacer(Modifier.weight(1f))

        TLPrimaryButton("다음", onClick = next)
        Spacer(Modifier.height(20.dp))
    }
}

/** 홈 연속달성 카드의 정적 목업 — 실데이터 화면과 같은 구성이라 실제 아이콘 리소스를 그대로 쓴다. */
@Composable
private fun StreakCardMock() {
    Column(
        Modifier.fillMaxWidth()
            .background(TL.surface, TL.cornerL)
            .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
            .padding(18.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("연속달성", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.width(5.dp))
                    Image(painterResource(R.drawable.stat_fire), null, Modifier.size(15.dp))
                }
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("3", color = TL.jade, fontSize = 38.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.width(2.dp))
                    Text("일", color = TL.muted, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                }
                Text(streakSummaryText(), fontSize = 13.sp)
            }
            Column(horizontalAlignment = Alignment.End) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("최고기록", color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.width(4.dp))
                    Image(painterResource(R.drawable.stat_average), null, Modifier.size(13.dp))
                }
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("56", color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Black)
                    Text("일", color = TL.muted, fontSize = 12.sp)
                }
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("평균 일정", color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.width(4.dp))
                    Image(painterResource(R.drawable.stat_record), null, Modifier.size(13.dp))
                }
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("4.2", color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Black)
                    Text("개", color = TL.muted, fontSize = 12.sp)
                }
            }
        }
        Spacer(Modifier.height(18.dp))
        Row(Modifier.fillMaxWidth()) {
            mockDay("목", "23", R.drawable.day_success, Modifier.weight(1f))
            mockDay("목", "23", R.drawable.day_fail, Modifier.weight(1f))
            mockDay("금", "24", R.drawable.day_half, Modifier.weight(1f))
            mockDay("토", "25", R.drawable.day_success, Modifier.weight(1f))
            mockDay("일", "26", R.drawable.day_success, Modifier.weight(1f), highlighted = true)
            mockDay("월", "27", R.drawable.day_not_started, Modifier.weight(1f))
        }
    }
}

@Composable
private fun streakSummaryText() = buildAnnotatedString {
    withStyle(SpanStyle(color = TL.muted, fontWeight = FontWeight.SemiBold)) { append("총 ") }
    withStyle(SpanStyle(color = TL.jade, fontWeight = FontWeight.Black)) { append("506") }
    withStyle(SpanStyle(color = TL.muted, fontWeight = FontWeight.SemiBold)) { append("시간 ") }
    withStyle(SpanStyle(color = TL.jade, fontWeight = FontWeight.Black)) { append("16") }
    withStyle(SpanStyle(color = TL.muted, fontWeight = FontWeight.SemiBold)) { append("분을 기록했어요!") }
}

@Composable
private fun mockDay(weekday: String, day: String, iconRes: Int, modifier: Modifier, highlighted: Boolean = false) {
    Column(
        modifier = modifier
            .background(if (highlighted) TL.raised else Color.Transparent, TL.cornerS)
            .padding(vertical = 7.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(weekday, color = if (highlighted) TL.paper else TL.faint, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Image(painterResource(iconRes), null, Modifier.size(22.dp))
        Text(day, color = if (highlighted) TL.paper else TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

// MARK: - 3. 권한 설정

@Composable
private fun PermissionStep(onFinish: () -> Unit) {
    var cameraGranted by remember { mutableStateOf<Boolean?>(null) }
    var notifGranted by remember { mutableStateOf<Boolean?>(null) }

    // 카드마다 제 권한만 요청한다 — iOS도 카메라/알림을 각각 묻는다. 하나로 묶으면
    // 알림 카드의 '계속'에서 카메라 권한 창까지 떠서 어느 카드에 답하는지 헷갈린다.
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        result[Manifest.permission.CAMERA]?.let { cameraGranted = it }
        result[Manifest.permission.POST_NOTIFICATIONS]?.let { notifGranted = it }
    }

    Column(
        Modifier.fillMaxSize().background(TL.ink)
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
    ) {
        Spacer(Modifier.height(60.dp))
        TLEyebrow("권한 설정")
        // 심사(5.1.1(iv)) — 허용을 권하는 문구·버튼 금지. 무엇에 쓰는지만 알리고
        // 결정은 시스템 창에 맡긴다.
        Text("두 가지 권한을 허용해 주세요", color = TL.paper, fontSize = 28.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(6.dp))
        Text("카메라와 알람에 사용됩니다. 지금 허용하지 않아도 앱을 둘러볼 수 있고, 촬영·알람을 쓸 때 다시 요청합니다.",
            color = TL.muted, fontSize = 15.sp, lineHeight = 21.sp)

        Spacer(Modifier.height(28.dp))
        TLCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.Icon(AppIcon.Camera, null, tint = TL.rec,
                    modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text("카메라", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text("알람 해제와 세션 기록에 사용합니다. 영상은 기기에만 저장되고 본인만 봅니다.",
                        color = TL.muted, fontSize = 13.sp)
                }
                PermissionStatusButton(cameraGranted) {
                    permissionLauncher.launch(arrayOf(Manifest.permission.CAMERA))
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.Icon(AppIcon.Bell, null, tint = TL.rec,
                    modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text("알림", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text("예약 시각의 알람과 10분 전 예고를 보냅니다.",
                        color = TL.muted, fontSize = 13.sp)
                }
                PermissionStatusButton(notifGranted) {
                    if (Build.VERSION.SDK_INT >= 33) {
                        permissionLauncher.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
                    } else {
                        notifGranted = true   // 33 미만은 알림 권한이 매니페스트만으로 자동 허용
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        TLCard {
            Row(verticalAlignment = Alignment.Top) {
                androidx.compose.material3.Icon(AppIcon.Drive, null, tint = TL.amber,
                    modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(14.dp))
                Column {
                    Text("저장공간 용량 확인", color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Text("영상 촬영 중간에 녹화가 중단되면, 이탈로 간주되어 패널티를 받을 수 있습니다. 용량 부족으로 타임랩스가 끊기지 않도록 저장공간을 미리 확보해 주세요.",
                        color = TL.amber, fontSize = 13.sp, lineHeight = 18.sp)
                }
            }
        }

        // 권한은 선택 — 거부해도 진행할 수 있다 (App Review 4.5.4/5.1.1)
        if (cameraGranted == false || notifGranted == false) {
            Spacer(Modifier.height(16.dp))
            Text("나중에 허용해도 괜찮아요. 촬영·알람 기능을 사용할 때 다시 안내해 드립니다.",
                color = TL.muted, fontSize = 13.sp)
        }

        Spacer(Modifier.height(28.dp))
        TLPrimaryButton("다음", onClick = onFinish)
        Spacer(Modifier.height(20.dp))
    }
}

@Composable
private fun PermissionStatusButton(granted: Boolean?, action: () -> Unit) {
    when (granted) {
        true -> androidx.compose.material3.Icon(AppIcon.Check, null, tint = TL.jade,
            modifier = Modifier.size(22.dp))
        false -> Text("✕", color = TL.rec, fontSize = 18.sp)
        null -> Box(
            Modifier.background(TL.paper, CircleShape)
                .clickable(onClick = action)
                .padding(horizontal = 14.dp, vertical = 8.dp),
        ) { Text("계속", color = TL.ink, fontSize = 14.sp, fontWeight = FontWeight.Black) }
    }
}
