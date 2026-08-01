package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.HowToReg
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.TabletAndroid
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WorkspacePremium
import com.singlemarks.angrymoti.ui.theme.TL
import kotlin.math.min

/**
 * 채도 제거 — 이모지(🔒🔥 등)는 시스템이 그리는 컬러 글리프라 Text의 color= 로는
 * 색을 바꿀 수 없다. 잠긴 카드를 무채색으로 보이게 하려면(iOS `.saturation(0)` 대응)
 * 렌더링 레이어 전체에 채도 매트릭스를 걸어야 한다.
 */
fun Modifier.grayscale(saturation: Float = 0f): Modifier = this.then(
    Modifier.drawWithContent {
        val paint = Paint().apply {
            colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(saturation) })
        }
        drawIntoCanvas { canvas ->
            canvas.saveLayer(Rect(Offset.Zero, size), paint)
            drawContent()
            canvas.restore()
        }
    }
)

/**
 * 앱 전역 아이콘 세트 — Filled(솔리드) 아이콘으로 통일 (아웃라인은 잘 안 보여서 교체).
 * 이전에 쓰던 Lucide 이름을 그대로 유지해 호출부 변경을 최소화한다.
 */
object AppIcon {
    val ChevronRight = Icons.Filled.ChevronRight
    val ChevronLeft = Icons.Filled.ChevronLeft
    val ChevronUp = Icons.Filled.KeyboardArrowUp
    val ChevronDown = Icons.Filled.KeyboardArrowDown
    val ChevronsUpDown = Icons.Filled.UnfoldMore
    val Check = Icons.Filled.Check
    // 알람 취소 사유 라디오 (iOS checkmark.circle.fill / circle 대응)
    val CheckCircle = Icons.Filled.CheckCircle
    val CircleEmpty = Icons.Filled.RadioButtonUnchecked
    val Users = Icons.Filled.Groups
    val UserRound = Icons.Filled.Person
    val UserCircle = Icons.Filled.AccountCircle   // 홈 헤더 마이페이지 (iOS person.crop.circle.fill)
    val UserRoundCheck = Icons.Filled.HowToReg
    val Clock = Icons.Filled.Schedule
    val CircleDot = Icons.Filled.LocalFireDepartment   // 활동 탭 = 불 아이콘
    val Tablet = Icons.Filled.TabletAndroid
    val SwitchCamera = Icons.Filled.Cameraswitch
    val Smartphone = Icons.Filled.Smartphone
    // 컴포즈 머티리얼 아이콘 세트엔 사이렌/경광등 글리프가 없어(iOS는 light.beacon.max),
    // 벨(차단 버튼)과 겹치지 않으면서 가장 '긴급'으로 읽히는 경고 삼각형을 쓴다.
    val Siren = Icons.Filled.Warning
    val Lock = Icons.Filled.Lock
    val Info = Icons.Filled.Info
    // 온보딩 권한 카드 (iOS camera.fill / bell.badge.fill / internaldrive.fill 대응)
    val Camera = Icons.Filled.PhotoCamera
    val Bell = Icons.Filled.NotificationsActive
    val Drive = Icons.Filled.Storage
    val Heart = Icons.Filled.Favorite
    val Headphones = Icons.Filled.Headphones
    val Crown = Icons.Filled.WorkspacePremium
    val Shield = Icons.Filled.Shield
    // 잠금 안내 카드 (iOS lock.slash.fill — 슬롯 초과 읽기 전용)
    val LockOpen = Icons.Filled.LockOpen
    val Copy = Icons.Filled.ContentCopy
    val CalendarDays = Icons.Filled.CalendarMonth
    val BellOff = Icons.Filled.NotificationsOff
    val BadgeCheck = Icons.Filled.Verified
    val ArrowDownToLine = Icons.Filled.Download
}

object TLFormat {
    fun durationLabel(minutes: Int): String {
        val h = minutes / 60; val m = minutes % 60
        return when {
            h > 0 && m > 0 -> "${h}시간 ${m}분"
            h > 0 -> "${h}시간"
            else -> "${m}분"
        }
    }

    fun hms(totalSeconds: Long): String {
        val s = totalSeconds.coerceAtLeast(0)
        val h = s / 3600; val m = (s % 3600) / 60; val sec = s % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%02d:%02d".format(m, sec)
    }

    fun timeLabel(startMinute: Int): String {
        val h = startMinute / 60; val m = startMinute % 60
        val ampm = if (h < 12) "오전" else "오후"
        val h12 = if (h % 12 == 0) 12 else h % 12
        return if (m == 0) "$ampm ${h12}시" else "$ampm ${h12}:%02d".format(m)
    }

    fun scoreLabel(points: Int): String = if (points >= 0) "+$points" else "$points"

    /** 오전/오후 12시간제 "a h:mm" (예: "오후 7:00") — iOS TLFormat.clock 1:1 */
    fun clock(epochMillis: Long): String {
        val cal = java.util.Calendar.getInstance().apply { timeInMillis = epochMillis }
        val h = cal.get(java.util.Calendar.HOUR_OF_DAY); val m = cal.get(java.util.Calendar.MINUTE)
        val ampm = if (h < 12) "오전" else "오후"
        val h12 = if (h % 12 == 0) 12 else h % 12
        return "$ampm $h12:${"%02d".format(m)}"
    }
}

/**
 * 숫자 표기 스타일 — iOS `.tlTimer(size)` 대응.
 * 고정폭 숫자(tnum)라 값이 바뀌어도 자릿수가 흔들리지 않고, Black 웨이트로 무게를 맞춘다.
 * (안드로이드 기본 폰트는 비례폭 숫자라 iOS monospacedDigit와 눈에 띄게 달라 보였다)
 */
fun tlTimerStyle(size: TextUnit): TextStyle = TextStyle(
    // style을 통째로 넘기면 LocalTextStyle이 대체되므로 폰트를 여기서 다시 지정한다.
    // (빠뜨리면 이 숫자만 시스템 폰트로 튀어 나온다)
    fontFamily = com.singlemarks.angrymoti.ui.theme.AppFont,
    fontSize = size,
    fontWeight = FontWeight.Black,
    fontFeatureSettings = "tnum",
)

/**
 * 권한이 막혔을 때의 안내 다이얼로그 — 시스템 창이 다시 뜨지 않는 상태에서
 * 사용자를 설정으로 보내는 유일한 경로다 (iOS의 '설정 열기' 알럿과 1:1).
 */
@Composable
fun TLSettingsDialog(
    title: String,
    message: String,
    confirmLabel: String = "설정 열기",
    dismissLabel: String = "나중에",
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = TL.surface,
        title = { Text(title, color = TL.paper, fontWeight = FontWeight.Black) },
        text = { Text(message, color = TL.muted, lineHeight = 20.sp) },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = onConfirm) {
                Text(confirmLabel, color = TL.rec, fontWeight = FontWeight.Black)
            }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = onDismiss) {
                Text(dismissLabel, color = TL.muted)
            }
        },
    )
}

/**
 * 잠금·경고 안내 카드 — iOS는 이런 안내를 TLCard + SF Symbol 아이콘 + paper 텍스트로 낸다.
 * (안드로이드는 아이콘 없이 amber 텍스트만 쓰던 자리를 통일)
 */
@Composable
fun TLNoticeCard(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String,
                 tint: Color = TL.amber) {
    TLCard {
        Row(verticalAlignment = Alignment.Top) {
            androidx.compose.material3.Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text(text, color = TL.paper, fontSize = 13.sp, lineHeight = 19.sp)
        }
    }
}

/** 대문자 트래킹 라벨 — iOS TLEyebrow (tracking 2.2) */
@Composable
fun TLEyebrow(text: String, color: Color = TL.muted) {
    Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
        letterSpacing = 2.2.sp, modifier = Modifier.padding(bottom = 8.dp))
}

/** 카드 — cornerL(22), hairline 0.6 테두리 (iOS TLCard) */
@Composable
fun TLCard(
    modifier: Modifier = Modifier,
    raised: Boolean = false,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(if (raised) TL.raised else TL.surface, TL.cornerL)
            .border(1.dp, TL.hairline.copy(alpha = 0.6f), TL.cornerL)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(16.dp),
        content = content,
    )
}

/** 프라이머리 버튼 — tint 배경 + 잉크 텍스트 (iOS TLPrimaryButtonStyle) */
@Composable
fun TLPrimaryButton(text: String, enabled: Boolean = true, tint: Color = TL.rec, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (enabled) tint else tint.copy(alpha = 0.35f), TL.cornerM)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = if (enabled) TL.ink else TL.ink.copy(alpha = 0.55f),
            fontSize = 17.sp, fontWeight = FontWeight.Bold)
    }
}

/** 고스트 버튼 — 헤어라인 테두리 (iOS TLGhostButtonStyle) */
@Composable
fun TLGhostButton(text: String, tint: Color = TL.paper, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, TL.hairline, TL.cornerM)
            .clickable(onClick = onClick)
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = tint, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * 누적 시간 "N시간 n분" 분해 — (숫자, 단위) 쌍 목록. 숫자는 강조색, 단위는 흐린색으로 그린다.
 * '시간 단위 내림'만 쓰면 1시간 미만이 전부 "0시간"으로 뭉개진다 — 분까지 보여준다
 * (시간이 0이면 분만, 분이 0이면 시간만). iOS styledHourMinute와 1:1.
 */
fun hourMinuteParts(totalSeconds: Int): List<Pair<String, String>> {
    val s = totalSeconds.coerceAtLeast(0)
    val h = s / 3600
    val m = (s % 3600) / 60
    val parts = mutableListOf<Pair<String, String>>()
    if (h > 0) parts.add("%,d".format(h) to "시간")
    if (m > 0 || h == 0) parts.add("$m" to "분")
    return parts
}

/** 성취 아이콘 판정 → 드로어블 — 홈 스트립·기록 캘린더 공용 (iOS DayOutcomeIcon.assetName 1:1) */
fun dayOutcomeDrawable(outcome: com.singlemarks.angrymoti.models.DayOutcome): Int = when (outcome) {
    com.singlemarks.angrymoti.models.DayOutcome.SUCCESS -> com.singlemarks.angrymoti.R.drawable.day_success
    com.singlemarks.angrymoti.models.DayOutcome.HALF -> com.singlemarks.angrymoti.R.drawable.day_half
    com.singlemarks.angrymoti.models.DayOutcome.FAIL -> com.singlemarks.angrymoti.R.drawable.day_fail
    com.singlemarks.angrymoti.models.DayOutcome.NOT_STARTED -> com.singlemarks.angrymoti.R.drawable.day_not_started
}

/** 핵심 대주제 6개 + 그룹의 고유 색. 직접 입력 태그만 null(회색 유지). iOS tagTint()와 1:1.
 *  '그룹'이 회색이던 시절엔 커스텀 태그와 같은 색이라 도넛에서 조각이 구분되지 않았다 —
 *  그룹은 옛 '작업' 골드를 물려받고, '작업'은 브랜드 라임으로 옮겼다. */
fun tagTint(name: String): Color? = when (name) {
    "공부"        -> Color(0xFF5B8DEF)   // 블루
    "독서"        -> Color(0xFFB07CF0)   // 바이올렛
    "운동"        -> Color(0xFFFF7A66)   // 코랄
    "작업"        -> Color(0xFFAFE746)   // 라임 (메인 브랜드 컬러)
    "그룹"        -> Color(0xFFF2A93C)   // 골드 (옛 '작업' 색 승계)
    "연주", "악기" -> Color(0xFFF473B3)   // 핑크
    "글쓰기"      -> Color(0xFF35C8AE)   // 틸
    else         -> null
}

/**
 * 캡슐 칩 텍스트용 타이트 스타일 — Compose 기본 Text는 폰트 자체 글리프보다 위아래로
 * 여백(includeFontPadding)이 더 붙어서, iOS와 같은 padding(12/7)을 줘도 캡슐이 더
 * 두꺼워 보인다. lineHeight를 fontSize에 맞춰 좁히고 플랫폼 여백을 꺼서 캡슐이
 * 글자 크기만큼만 커지게 한다.
 */
/**
 * 원형 배지('나') 안 글자 — Box(contentAlignment = Center)로 감싸도 글자가 아래로
 * 치우쳐 보인다. includeFontPadding이 한글 글자 위아래에 폰트 여백을 얹는데, 그 여백까지
 * 포함해 가운데를 잡기 때문이다. 여백을 끄고 실제 글자 높이 기준으로 정렬한다.
 */
val circleBadgeTextStyle = TextStyle(
    fontFamily = com.singlemarks.angrymoti.ui.theme.AppFont,
    platformStyle = PlatformTextStyle(includeFontPadding = false),
    lineHeightStyle = LineHeightStyle(
        alignment = LineHeightStyle.Alignment.Center,
        trim = LineHeightStyle.Trim.Both,
    ),
)

private val tightChipTextStyle = TextStyle(
    // 위 tlTimerStyle과 같은 이유로 폰트 명시 (style 인자는 LocalTextStyle을 대체한다)
    fontFamily = com.singlemarks.angrymoti.ui.theme.AppFont,
    lineHeight = 13.sp,
    platformStyle = PlatformTextStyle(includeFontPadding = false),
    lineHeightStyle = LineHeightStyle(
        alignment = LineHeightStyle.Alignment.Center,
        trim = LineHeightStyle.Trim.Both,
    ),
)

/** 태그 칩 — 프리셋 6개+그룹은 고유색, 그 외(커스텀)는 회색. 선택 시 원색 캡슐 (iOS TagChip) */
@Composable
fun TagChip(name: String, selected: Boolean, onClick: () -> Unit) {
    val tint = tagTint(name)
    val bg = when {
        tint == null -> if (selected) TL.paper else TL.surface
        selected -> tint
        else -> tint.copy(alpha = 0.16f)
    }
    val border = when {
        tint == null -> if (selected) Color.Transparent else TL.hairline
        selected -> Color.Transparent
        else -> tint.copy(alpha = 0.38f)
    }
    val fg = when {
        tint == null -> if (selected) TL.ink else TL.muted
        // 밝은 원색(라임 등) 위 흰 글씨는 묻힌다 — 상대 휘도 0.6 기준으로 잉크 반전 (iOS 1:1)
        selected -> if (tint.luminance() > 0.6f) TL.ink else Color.White
        else -> tint
    }
    Box(
        modifier = Modifier
            .background(bg, CircleShape)
            .border(1.dp, border, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Text(name, color = fg, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            style = tightChipTextStyle)
    }
}

/** 목록 표시 전용 태그 칩 — TagChip의 비선택 색 규칙(원색 글자·16% 배경·38% 테두리)과 동일.
 * 일정 탭 행처럼 탭 동작이 없는 자리에서 쓴다 (iOS는 같은 TagChip 하나로 쓰지만
 * 안드로이드 목록 행은 칩 크기가 달라 표시용을 분리). */
@Composable
fun TagBadge(name: String, alpha: Float = 1f) {
    val tint = tagTint(name)
    Box(
        modifier = Modifier
            .graphicsLayer { this.alpha = alpha }
            .background(tint?.copy(alpha = 0.16f) ?: TL.surface, CircleShape)
            .border(1.dp, tint?.copy(alpha = 0.38f) ?: TL.hairline, CircleShape)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(name, color = tint ?: TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 뒤로가기 원형 버튼 (마이페이지 등 상단) */
@Composable
fun TLCircleBack(onClick: () -> Unit) {
    Box(
        modifier = Modifier.size(44.dp)
            .background(TL.surface, CircleShape)
            .border(1.dp, TL.hairline, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.material3.Icon(
            AppIcon.ChevronLeft,
            contentDescription = "뒤로", tint = TL.paper,
            modifier = Modifier.size(22.dp))
    }
}

/** 상단 필 버튼 (닫기 / 저장) — 예약 편집 상단 */
@Composable
fun TLPillButton(text: String, tint: Color = TL.paper, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(TL.surface, CircleShape)
            .border(1.dp, TL.hairline, CircleShape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 10.dp),
    ) {
        Text(text, color = if (enabled) tint else TL.faint, fontSize = 15.sp, fontWeight = FontWeight.Bold)
    }
}

/** 공용 화면 헤더 — 원형 뒤로가기 + 중앙 타이틀 (모든 서브 화면 통일) */
@Composable
fun TLScreenHeader(title: String, onBack: () -> Unit) {
    androidx.compose.foundation.layout.Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(bottom = 20.dp),
    ) {
        TLCircleBack(onClick = onBack)
        androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
        Text(title, color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
        androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
        androidx.compose.foundation.layout.Spacer(Modifier.size(44.dp))
    }
}

/** 브랜드 시그니처 (세리프, 흐리게) */
@Composable
fun BrandSignature(modifier: Modifier = Modifier) {
    Text("Culture Design Corperation ‘      ’", color = TL.faint, fontSize = 13.sp,
        fontFamily = FontFamily.Serif,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        modifier = modifier.fillMaxWidth())
}

// MARK: 시그니처 — 교실 벽시계 다이얼 (iOS FocusDial 1:1)
// 흰 판 위 12시부터 시계 방향 '남은 시간' 빨간 부채꼴, 바깥 3단 눈금(1·5·15분), 중심 잉크 점.

@Composable
fun FocusDial(
    remaining: Float,               // 남은 비율 0~1
    modifier: Modifier = Modifier,
    tint: Color = TL.rec,
    totalMinutes: Int = 60,
) {
    val clamped = remaining.coerceIn(0f, 1f)
    val minorCount = when {
        totalMinutes < 90 -> 60
        totalMinutes < 240 -> 36
        else -> 24
    }
    Canvas(modifier.aspectRatio(1f)) {
        val s = min(size.width, size.height)
        val c = Offset(size.width / 2, size.height / 2)
        val majorLen = s * 0.060f; val midLen = s * 0.040f; val minorLen = s * 0.022f
        val majorW = maxOf(2f * density, s * 0.012f)
        val midW = maxOf(1.5f * density, s * 0.008f)
        val minorW = maxOf(1f * density, s * 0.005f)
        val outerTip = s / 2 - s * 0.006f
        val dialInset = majorLen + s * 0.04f
        val minorStep = minorCount / 12

        fun tick(angleDeg: Float, len: Float, w: Float, color: Color) {
            rotate(angleDeg, pivot = c) {
                drawLine(color,
                    start = Offset(c.x, c.y - outerTip),
                    end = Offset(c.x, c.y - (outerTip - len)),
                    strokeWidth = w, cap = StrokeCap.Round)
            }
        }
        for (i in 0 until minorCount) if (i % minorStep != 0)
            tick(i * 360f / minorCount, minorLen, minorW, TL.faint)
        for (i in 0 until 12) if (i % 3 != 0)
            tick(i * 30f, midLen, midW, TL.muted)
        for (i in 0 until 4)
            tick(i * 90f, majorLen, majorW, TL.paper)

        // 흰 시계판
        val faceR = s / 2 - dialInset
        drawCircle(Color.White, radius = faceR, center = c)
        // 남은 시간 부채꼴 (12시 → 시계 방향)
        drawArc(tint, startAngle = -90f, sweepAngle = 360f * clamped, useCenter = true,
            topLeft = Offset(c.x - faceR, c.y - faceR), size = Size(faceR * 2, faceR * 2))
        // 흰 바늘 — 부채꼴의 진행 경계를 가리킨다 (iOS와 공통)
        val handAngle = Math.toRadians(-90.0 + 360.0 * clamped)
        drawLine(Color.White,
            start = c,
            end = Offset(c.x + faceR * kotlin.math.cos(handAngle).toFloat(),
                         c.y + faceR * kotlin.math.sin(handAngle).toFloat()),
            strokeWidth = maxOf(3f * density, s * 0.014f), cap = StrokeCap.Round)
        // 중심점
        drawCircle(TL.ink, radius = s * 0.035f, center = c)
    }
}

/** REC 링 — progress 링 + 12시 REC 점 (iOS RECRing) */
@Composable
fun RECRing(progress: Float, modifier: Modifier = Modifier, tint: Color = TL.rec, lineWidth: Float = 12f) {
    Canvas(modifier.aspectRatio(1f)) {
        val stroke = lineWidth * density
        val r = min(size.width, size.height) / 2 - stroke / 2
        val c = Offset(size.width / 2, size.height / 2)
        drawCircle(TL.hairline, radius = r, center = c, style = Stroke(stroke))
        drawArc(tint, startAngle = -90f, sweepAngle = 360f * progress.coerceIn(0.003f, 1f),
            useCenter = false,
            topLeft = Offset(c.x - r, c.y - r), size = Size(r * 2, r * 2),
            style = Stroke(stroke, cap = StrokeCap.Round))
    }
}
