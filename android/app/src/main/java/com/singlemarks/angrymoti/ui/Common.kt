package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.ui.theme.TL

object TLFormat {
    fun durationLabel(minutes: Int): String {
        val h = minutes / 60; val m = minutes % 60
        return when {
            h == 0 -> "${m}분"
            m == 0 -> "${h}시간"
            else -> "${h}시간 ${m}분"
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
            .background(if (raised) TL.raised else TL.surface, TL.cornerM)
            .border(1.dp, TL.hairline, TL.cornerM)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(16.dp),
        content = content,
    )
}

@Composable
fun TLEyebrow(text: String) {
    Text(text, color = TL.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold,
        letterSpacing = 1.2.sp, modifier = Modifier.padding(bottom = 8.dp))
}

@Composable
fun TLPrimaryButton(text: String, enabled: Boolean = true, tint: Color = TL.rec, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (enabled) tint else TL.raised, TL.cornerM)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 16.dp),
        contentAlignment = androidx.compose.ui.Alignment.Center,
    ) {
        Text(text, color = if (enabled) TL.paper else TL.faint,
            fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun TagChip(name: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(if (selected) TL.rec else TL.surface, TL.cornerS)
            .border(1.dp, if (selected) TL.rec else TL.hairline, TL.cornerS)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp)
    ) {
        Text(name, color = if (selected) TL.paper else TL.muted, fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold)
    }
}
