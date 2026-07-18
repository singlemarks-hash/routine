package com.singlemarks.angrymoti.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** iOS Theme.swift(TL 팔레트) 대응 — 다크 고정 */
object TL {
    val ink = Color(0xFF0E0F12)        // 배경
    val surface = Color(0xFF17181D)
    val raised = Color(0xFF1F2127)
    val hairline = Color(0xFF2A2C33)
    val paper = Color(0xFFF2F1EC)      // 본문
    val muted = Color(0xFF9A9BA3)
    val faint = Color(0xFF5E5F66)
    val rec = Color(0xFFE53935)        // 브랜드 레드
    val jade = Color(0xFF2FBF8F)       // 성공/상점
    val amber = Color(0xFFF2B233)      // 경고

    val cornerS = RoundedCornerShape(10.dp)
    val cornerM = RoundedCornerShape(14.dp)
    val cornerL = RoundedCornerShape(20.dp)
}

private val scheme = darkColorScheme(
    primary = TL.rec,
    background = TL.ink,
    surface = TL.surface,
    onPrimary = TL.paper,
    onBackground = TL.paper,
    onSurface = TL.paper,
)

@Composable
fun AngryMotiTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
