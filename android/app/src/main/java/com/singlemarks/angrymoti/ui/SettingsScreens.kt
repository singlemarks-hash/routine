package com.singlemarks.angrymoti.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.AppState
import com.singlemarks.angrymoti.R
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.services.SubscriptionManager
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

object Legal {
    const val TERMS_URL = "https://singlemark.notion.site/39f41b10f64b8026ab19cab6bf66ade2"
    const val PRIVACY_URL = "https://singlemark.notion.site/39f41b10f64b80d2acaffcb5815106a9"
    const val SUBSCRIPTION_DISCLOSURE =
        "앵그리모티 멤버십은 월 단위 자동 갱신 구독입니다. 현재 결제 기간이 끝나기 전에 해지하지 않으면 " +
        "등록된 Google 계정으로 자동 갱신·청구됩니다. 구매 후 Play 스토어 구독 설정에서 언제든 관리·해지할 수 있습니다."
}

/** 마이페이지 — 메뉴 허브 */
@Composable
fun MyPageScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var sub by remember { mutableStateOf("menu") }   // menu | profile | intensity | paywall | ledger

    when (sub) {
        "profile" -> { ProfileEditScreen(onBack = { sub = "menu" }, openPaywall = { sub = "paywall" }); return }
        "intensity" -> { IntensityScreen(onBack = { sub = "menu" }); return }
        "paywall" -> { PaywallScreen(onBack = { sub = "menu" }); return }
        "ledger" -> { LedgerScreen(onBack = { sub = "menu" }); return }
    }

    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 16.dp)) {
            Text("← 뒤로", color = TL.muted, fontSize = 15.sp,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp))
            Spacer(Modifier.weight(1f))
            Text("마이페이지", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f)); Spacer(Modifier.width(48.dp))
        }
        MenuRow("👤  프로필 및 구독 관리") { sub = "profile" }
        MenuRow("🌶️  강도 설정") { sub = "intensity" }
        MenuRow("👑  멤버십") { sub = "paywall" }
        MenuRow("🧾  점수 원장") { sub = "ledger" }
        MenuRow("📄  이용약관") { open(Legal.TERMS_URL) }
        MenuRow("🔒  개인정보처리방침") { open(Legal.PRIVACY_URL) }
        MenuRow("🌐  앱 언어 — 한국어 ✓ (English 준비 중)") {}
        Spacer(Modifier.height(40.dp))
        Text("Culture Design Corperation ‘      ’", color = TL.faint, fontSize = 11.sp,
            textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun MenuRow(label: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp)
            .background(TL.surface, TL.cornerM).clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        Text("›", color = TL.faint, fontSize = 18.sp)
    }
}

/** 프로필 및 구독 관리 — 프로필 카드(로그아웃 포함) + 구독 카드 + 최하단 계정 삭제 */
@Composable
fun ProfileEditScreen(onBack: () -> Unit, openPaywall: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val user by AccountStore.user.collectAsState()
    val isPro by SubscriptionManager.isPro.collectAsState()
    val db = remember { AppDb.get(context) }
    val owner = AccountStore.currentUserID
    val events by db.scores().allFlow(owner).collectAsState(initial = emptyList())
    var confirmDelete by remember { mutableStateOf(false) }

    val plus = events.filter { it.points > 0 }.sumOf { it.points }
    val minus = events.filter { it.points < 0 }.sumOf { it.points }

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 16.dp)) {
            Text("← 뒤로", color = TL.muted, fontSize = 15.sp,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp))
            Spacer(Modifier.weight(1f))
            Text("프로필 및 구독 관리", color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f)); Spacer(Modifier.width(48.dp))
        }

        TLCard {
            Text(user?.name ?: "게스트", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            user?.email?.let { Text(it, color = TL.muted, fontSize = 13.sp) }
            Text(when (user?.provider) {
                "google" -> "Google 계정"; "email" -> "이메일 계정"; else -> "게스트 (기기 저장)"
            }, color = TL.faint, fontSize = 12.sp)
            Spacer(Modifier.height(14.dp))
            Row {
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("+$plus", color = TL.jade, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text("상점", color = TL.muted, fontSize = 12.sp)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("$minus", color = TL.rec, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text("벌점", color = TL.muted, fontSize = 12.sp)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("${plus + minus}", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text("총점", color = TL.muted, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(12.dp))
            Text("로그아웃", color = TL.muted, fontSize = 13.sp, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().clickable { AccountStore.signOut() }.padding(6.dp))
        }

        Spacer(Modifier.height(14.dp))
        TLCard(onClick = openPaywall) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.moti_member), null, Modifier.size(44.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(if (isPro) "앵그리모티 멤버십 사용 중" else "앵그리모티 멤버십",
                        color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text(
                        if (isPro) "멤버십 혜택 적용 중 — 슬롯 ${SlotPolicy.MEMBER_FLOOR_SLOTS}개부터·워터마크 제거·미친 매운맛."
                        else "슬롯 ${SlotPolicy.MEMBER_FLOOR_SLOTS}개부터 · 워터마크 제거 · 미친 매운맛 즉시 해제.",
                        color = TL.muted, fontSize = 12.sp)
                }
                if (isPro) Text("👑", fontSize = 20.sp)
            }
        }

        Spacer(Modifier.height(40.dp))
        Text("계정 삭제", color = TL.rec, fontSize = 15.sp, fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().background(TL.raised, TL.cornerM)
                .clickable { confirmDelete = true }.padding(vertical = 16.dp))
        Text("기기·서버의 모든 데이터가 즉시 완전 삭제되며 복구할 수 없습니다.",
            color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
        Spacer(Modifier.height(24.dp))
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            containerColor = TL.surface,
            title = { Text("정말 삭제할까요?", color = TL.paper) },
            text = { Text("모든 예약·세션·점수·영상이 즉시 삭제되고 되돌릴 수 없어요.", color = TL.muted) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch(Dispatchers.IO) {
                        val uid = AccountStore.currentUserID
                        for (s in db.sessions().all(uid)) {
                            CameraRecorder.deleteFiles(context, s.videoFileName, s.thumbnailFileName)
                        }
                        db.reservations().deleteAll(uid)
                        db.sessions().deleteAll(uid)
                        db.scores().deleteAll(uid)
                        AccountStore.deleteAccount()
                        withContext(Dispatchers.Main) { onBack() }
                    }
                }) { Text("삭제", color = TL.rec, fontWeight = FontWeight.Black) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("취소", color = TL.muted) }
            },
        )
    }
}

/** 강도 설정 — 상향 즉시 / 하향 익일 0시, 잠금 해제 n/3 */
@Composable
fun IntensityScreen(onBack: () -> Unit) {
    val intensity by AppState.intensity.collectAsState()
    val completions by AppState.spicyCompletions.collectAsState()
    val isPro by SubscriptionManager.isPro.collectAsState()

    Column(Modifier.fillMaxSize().background(TL.ink).padding(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 16.dp)) {
            Text("← 뒤로", color = TL.muted, fontSize = 15.sp,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp))
            Spacer(Modifier.weight(1f))
            Text("강도 설정", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f)); Spacer(Modifier.width(48.dp))
        }
        IntensityCard(Intensity.SPICY, intensity == Intensity.SPICY, locked = false) {
            AppState.requestIntensityChange(Intensity.SPICY)
        }
        Spacer(Modifier.height(10.dp))
        val locked = !(completions >= 3 || isPro)
        IntensityCard(Intensity.INSANE, intensity == Intensity.INSANE, locked = locked) {
            AppState.requestIntensityChange(Intensity.INSANE)
        }
        Spacer(Modifier.height(12.dp))
        if (AppState.pendingDowngrade) {
            Text("매운맛으로 하향 예약됨 — 다음날 0시부터 적용됩니다", color = TL.amber, fontSize = 13.sp)
            Spacer(Modifier.height(6.dp))
        }
        Text("올리는 건 즉시 적용되고, 내리는 건 다음날 0시부터 적용됩니다. " +
            "미친 매운맛은 매운맛 완주 3회 후 잠금 해제됩니다. " +
            "(현재 ${minOf(completions, 3)}/3 · 멤버십은 조건 없이 바로 사용)",
            color = TL.faint, fontSize = 12.sp)
    }
}

/** 페이월 — 멤버십 (Google Play Billing) */
@Composable
fun PaywallScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val isPro by SubscriptionManager.isPro.collectAsState()
    val product by SubscriptionManager.product.collectAsState()

    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    Column(
        Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("← 뒤로", color = TL.muted, fontSize = 15.sp,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp))
            Spacer(Modifier.weight(1f))
        }
        Image(painterResource(R.drawable.moti_member), null, Modifier.size(140.dp))
        Text("앵그리모티 멤버십", color = TL.paper, fontSize = 24.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(20.dp))
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Benefit("활동 슬롯 최소 ${SlotPolicy.MEMBER_FLOOR_SLOTS}개부터 시작 (무료는 2개)")
            Benefit("타임랩스 워터마크 제거")
            Benefit("미친 매운맛 즉시 잠금 해제 (완주 3회 조건 없음)")
            Benefit("멤버들과 함께: 랭킹게임 (준비 중)")
            Benefit("그 외 추가되는 멤버십 기능 모두 포함")
        }
        Spacer(Modifier.height(24.dp))
        if (isPro) {
            Text("멤버십 사용 중이에요 👑", color = TL.jade, fontSize = 16.sp, fontWeight = FontWeight.Bold)
        } else if (product != null) {
            TLPrimaryButton("${SubscriptionManager.displayPrice} / 월 구독하기", tint = TL.jade) {
                (context as? Activity)?.let { SubscriptionManager.purchase(it) }
            }
        } else {
            Text("구독 상품을 불러오는 중입니다…", color = TL.faint, fontSize = 13.sp)
        }
        Spacer(Modifier.height(10.dp))
        Text("구매 복원", color = TL.muted, fontSize = 13.sp,
            modifier = Modifier.clickable { SubscriptionManager.refresh() }.padding(6.dp))
        Spacer(Modifier.height(12.dp))
        Text(Legal.SUBSCRIPTION_DISCLOSURE, color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("이용약관", color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.TERMS_URL) })
            Text("·", color = TL.faint)
            Text("개인정보처리방침", color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.PRIVACY_URL) })
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Benefit(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("✓", color = TL.jade, fontSize = 16.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.width(10.dp))
        Text(text, color = TL.paper, fontSize = 14.sp)
    }
}

/** 점수 원장 */
@Composable
fun LedgerScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    val events by db.scores().allFlow(AccountStore.currentUserID).collectAsState(initial = emptyList())

    Column(Modifier.fillMaxSize().background(TL.ink).padding(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 16.dp)) {
            Text("← 뒤로", color = TL.muted, fontSize = 15.sp,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp))
            Spacer(Modifier.weight(1f))
            Text("점수 원장", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f)); Spacer(Modifier.width(48.dp))
        }
        androidx.compose.foundation.lazy.LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(events.size) { i ->
                val e = events[i]
                TLCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(e.type.title, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            e.note?.let { Text(it, color = TL.faint, fontSize = 12.sp) }
                            Text(java.text.SimpleDateFormat("M월 d일 HH:mm", java.util.Locale.KOREA)
                                .format(java.util.Date(e.timestamp)), color = TL.faint, fontSize = 11.sp)
                        }
                        Text(TLFormat.scoreLabel(e.points),
                            color = if (e.points >= 0) TL.jade else TL.rec,
                            fontSize = 16.sp, fontWeight = FontWeight.Black)
                    }
                }
            }
        }
    }
}
