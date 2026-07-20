package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.composables.icons.lucide.*
import com.singlemarks.angrymoti.ui.theme.TL
import kotlin.math.min

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

/** 태그 칩 — 선택 시 종이색 캡슐 + 잉크 텍스트 (iOS TagChip) */
@Composable
fun TagChip(name: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(if (selected) TL.paper else TL.surface, CircleShape)
            .border(1.dp, if (selected) Color.Transparent else TL.hairline, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(name, color = if (selected) TL.ink else TL.muted, fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold)
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
            Lucide.ChevronLeft,
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
        // 흰 바늘 — 부채꼴의 진행 경계를 가리킨다 (iOS 1:1)
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
