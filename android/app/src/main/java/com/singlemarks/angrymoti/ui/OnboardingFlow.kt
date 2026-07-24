package com.singlemarks.angrymoti.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.R
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.ui.theme.TL

/**
 * 온보딩 3단계 — 1. 컨셉 / 2. 권한(카메라·알림) / 3. 강도
 * 미친 매운맛은 매운맛 완주 3회 후 잠금 해제 (멤버십은 조건 없이).
 */
@Composable
fun OnboardingFlow() {
    var step by remember { mutableIntStateOf(0) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { step = 2 }

    Column(
        modifier = Modifier.fillMaxSize().background(TL.ink).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(48.dp))
        when (step) {
            0 -> {
                Image(painterResource(R.drawable.onboarding_character), null, Modifier.size(140.dp))
                Spacer(Modifier.height(28.dp))
                Text("알람을 끄는 유일한 방법", color = TL.paper, fontSize = 24.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(10.dp))
                Text(
                    "예약한 시각에 알람이 울리면,\n전면 카메라 타임랩스 촬영을 시작해야만 꺼집니다.\n미루기와 노쇼는 벌점으로 기록됩니다.",
                    color = TL.muted, fontSize = 15.sp, textAlign = TextAlign.Center, lineHeight = 22.sp,
                )
                Spacer(Modifier.weight(1f))
                TLPrimaryButton("시작하기") { step = 1 }
            }
            1 -> {
                Text("권한이 필요해요", color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(20.dp))
                TLCard {
                    Text("📷  카메라", color = TL.paper, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    Text("알람 해제와 타임랩스 촬영에 사용해요. 영상은 기기에만 저장됩니다.",
                        color = TL.muted, fontSize = 13.sp)
                }
                Spacer(Modifier.height(12.dp))
                TLCard {
                    Text("🔔  알림", color = TL.paper, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    Text("예약한 활동 시각에 알람을 울리기 위해 필요해요.", color = TL.muted, fontSize = 13.sp)
                }
                Spacer(Modifier.height(12.dp))
                // 저장공간 부족 경고 — 촬영 중단이 이탈로 간주될 수 있음을 미리 고지
                TLCard {
                    Text("💾  저장공간 용량 확인", color = TL.paper, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    Spacer(Modifier.height(4.dp))
                    Text("저장공간이 부족하여 중간에 타임랩스가 중단되면, 이탈로 간주되어 패널티를 받을 수 있습니다. 미리 충분한 저장공간을 꼭 확보해 주세요.",
                        color = TL.amber, fontSize = 13.sp, lineHeight = 19.sp)
                }
                Spacer(Modifier.weight(1f))
                TLPrimaryButton("권한 허용하기") {
                    val perms = mutableListOf(Manifest.permission.CAMERA)
                    if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
                    permissionLauncher.launch(perms.toTypedArray())
                }
            }
            else -> {
                Text("강도를 선택하세요", color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(20.dp))
                IntensityCard(Intensity.SPICY, selected = true, locked = false) {}
                Spacer(Modifier.height(12.dp))
                IntensityCard(Intensity.INSANE, selected = false, locked = true) {}
                Spacer(Modifier.height(14.dp))
                Text("미친 매운맛은 멤버십 전용이에요.\n무료로는 매운맛으로 시작하고, 멤버십에서 열 수 있어요.",
                    color = TL.faint, fontSize = 13.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.weight(1f))
                TLPrimaryButton("매운맛으로 시작") {
                    Prefs.setIntensityRaw(
                        com.singlemarks.angrymoti.services.AccountStore.currentUserID,
                        Intensity.SPICY.raw)
                    com.singlemarks.angrymoti.AppState.completeOnboarding()
                }
            }
        }
        Spacer(Modifier.height(20.dp))
    }
}

@Composable
fun IntensityCard(intensity: Intensity, selected: Boolean, locked: Boolean, onClick: () -> Unit) {
    TLCard(raised = selected, onClick = onClick) {
        androidx.compose.foundation.layout.Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(intensity.emoji, fontSize = 28.sp)
            Column(Modifier.weight(1f)) {
                androidx.compose.foundation.layout.Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(intensity.title, color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    if (locked) Text("🔒 잠금 해제 전", color = TL.faint, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    if (selected) Text("✓", color = TL.jade, fontSize = 16.sp, fontWeight = FontWeight.Black)
                }
                Text(intensity.subtitle, color = TL.muted, fontSize = 13.sp)
            }
        }
    }
}
