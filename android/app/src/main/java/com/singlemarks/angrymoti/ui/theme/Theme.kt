package com.singlemarks.angrymoti.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * iOS Theme.swift와 1:1 — 다크룸(레코딩 부스) 무드.
 * 빨강(rec)은 강제·촬영·실패에만, 옥색(jade)은 완주·상점에만, 앰버는 경고·유예에만.
 */
object TL {
    val ink = Color(0xFF0F0F13)        // 배경: 깊은 잉크 블랙(살짝 보라 기운)
    val surface = Color(0xFF1A1A21)    // 카드 표면
    val raised = Color(0xFF23232C)     // 떠 있는 표면(시트·강조 카드)
    val hairline = Color(0xFF2F2F3A)
    val rec = Color(0xFFFF4B33)        // REC 레드
    val jade = Color(0xFF45D6A0)       // 완주·상점
    val amber = Color(0xFFFFB020)      // 경고·유예·임박
    val paper = Color(0xFFF4F2EC)      // 본문(따뜻한 종이색)
    val muted = Color(0xFF9A98A3)
    val faint = Color(0xFF55535E)

    val cornerL = RoundedCornerShape(22.dp)
    val cornerM = RoundedCornerShape(14.dp)
    val cornerS = RoundedCornerShape(9.dp)
}

private val scheme = darkColorScheme(
    primary = TL.rec,
    background = TL.ink,
    surface = TL.surface,
    onPrimary = TL.ink,
    onBackground = TL.paper,
    onSurface = TL.paper,
)

@Composable
fun AngryMotiTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
