package com.singlemarks.angrymoti.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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

    // 뒤로가기: 마이페이지 내부 화면에서는 메뉴로 복귀.
    // 메뉴에서는 가로채지 않아 HomeShell의 BackHandler(홈으로 복귀)로 넘어간다.
    BackHandler(enabled = sub != "menu") { sub = "menu" }

    when (sub) {
        "profile" -> { ProfileEditScreen(onBack = { sub = "menu" }, openPaywall = { sub = "paywall" }); return }
        "intensity" -> { IntensityScreen(onBack = { sub = "menu" }); return }
        "paywall" -> { PaywallScreen(onBack = { sub = "menu" }); return }
        "ledger" -> { LedgerScreen(onBack = { sub = "menu" }); return }
        "privacy" -> { PrivacyScreen(onBack = { sub = "menu" }); return }
    }

    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        // 상단: 원형 뒤로가기 + 중앙 타이틀 (iOS 1:1)
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 24.dp)) {
            TLCircleBack(onClick = onBack)
            Spacer(Modifier.weight(1f))
            Text("마이페이지", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f)); Spacer(Modifier.width(44.dp))
        }
        // 아이콘 메뉴 (투명 행) — iOS와 동일 구성
        IconMenuRow(AppIcon.UserRoundCheck, "프로필 및 구독 관리") { sub = "profile" }
        IconMenuRow(AppIcon.Headphones, "고객센터") {
            context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:singlemarks@gmail.com")))
        }
        IconMenuRow(AppIcon.Heart, "개발자 응원하기") { sub = "paywall" }

        androidx.compose.material3.HorizontalDivider(
            color = TL.hairline, modifier = Modifier.padding(vertical = 18.dp))

        // 텍스트 메뉴 (투명 행)
        PlainMenuRow("강도 설정") { sub = "intensity" }
        PlainMenuRow("프라이버시") { sub = "privacy" }
        PlainMenuRow("점수 원장") { sub = "ledger" }
        PlainMenuRow("앱 언어") {}
        PlainMenuRow("이용약관") { open(Legal.TERMS_URL) }
        PlainMenuRow("개인정보처리방침") { open(Legal.PRIVACY_URL) }

        Spacer(Modifier.height(48.dp))
        BrandSignature()
    }
}

@Composable
private fun IconMenuRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        androidx.compose.material3.Icon(icon, null, tint = TL.paper,
            modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(16.dp))
        Text(label, color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        androidx.compose.material3.Icon(
            AppIcon.ChevronRight,
            null, tint = TL.faint, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun PlainMenuRow(label: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = TL.paper, fontSize = 16.sp)
        Spacer(Modifier.weight(1f))
        androidx.compose.material3.Icon(
            AppIcon.ChevronRight,
            null, tint = TL.faint, modifier = Modifier.size(18.dp))
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
        TLScreenHeader("프로필 및 구독 관리", onBack = onBack)

        // 프로필 카드 — 아바타 이니셜 + 이름/이메일 + 제공자 칩 + 구분선 + 점수 3단 + 로그아웃 (iOS 1:1)
        TLCard(raised = true) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(52.dp).background(TL.rec.copy(alpha = 0.2f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text((user?.name ?: user?.email ?: "?").take(1).uppercase(),
                        color = TL.rec, fontSize = 20.sp, fontWeight = FontWeight.Black)
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(user?.name ?: user?.email ?: "회원",
                        color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    user?.email?.let { Text(it, color = TL.muted, fontSize = 12.sp) }
                }
                TagChip(when (user?.provider) {
                    "google" -> "Google"; "email" -> "이메일"; else -> "게스트"
                }, selected = false, onClick = {})
            }
            Spacer(Modifier.height(14.dp))
            androidx.compose.material3.HorizontalDivider(color = TL.hairline)
            Spacer(Modifier.height(14.dp))
            Row {
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("+$plus", color = TL.jade, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text("내 상점", color = TL.muted, fontSize = 12.sp)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("$minus", color = TL.rec, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text("내 벌점", color = TL.muted, fontSize = 12.sp)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("${plus + minus}",
                        color = if (plus + minus >= 0) TL.paper else TL.rec,
                        fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text("총점", color = TL.muted, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(10.dp))
            Text("로그아웃", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().clickable { AccountStore.signOut() }.padding(6.dp))
        }

        // 구독 카드 — 눈썹 라벨 + 카드(멤버는 raised) + 구독하기/구매 복원 (iOS 1:1)
        Spacer(Modifier.height(18.dp))
        TLEyebrow("구독")
        TLCard(raised = isPro) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if (isPro) "앵그리모티 멤버십 사용 중" else "앵그리모티 멤버십",
                        color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        if (isPro) "멤버십 혜택 적용 중 — 슬롯 ${SlotPolicy.MEMBER_FLOOR_SLOTS}개부터·워터마크 제거·미친 매운맛."
                        else "슬롯 ${SlotPolicy.MEMBER_FLOOR_SLOTS}개부터 · 워터마크 제거 · 미친 매운맛 즉시 해제.",
                        color = TL.muted, fontSize = 13.sp)
                }
                if (isPro) {
                    androidx.compose.material3.Icon(
                        AppIcon.BadgeCheck,
                        null, tint = TL.jade, modifier = Modifier.size(24.dp))
                }
            }
            if (!isPro) {
                Spacer(Modifier.height(12.dp))
                TLPrimaryButton("구독하기", tint = TL.jade, onClick = openPaywall)
            }
            Spacer(Modifier.height(10.dp))
            Text("구매 복원", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().clickable { SubscriptionManager.refresh() }.padding(4.dp))
        }
        Spacer(Modifier.height(10.dp))
        Text(Legal.SUBSCRIPTION_DISCLOSURE, color = TL.faint, fontSize = 11.sp)

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
        TLScreenHeader("강도 설정", onBack = onBack)
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
            TLCircleBack(onClick = onBack)
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
        Spacer(Modifier.height(18.dp))
        CouponEntry()
        Spacer(Modifier.height(16.dp))
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

/** 프로모션 쿠폰 입력 — 결제 없이 앱 내부 권한(기간제)을 부여받는다. 만료 시 자동 강등. */
@Composable
private fun CouponEntry() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Text("프로모션 쿠폰이 있으신가요?", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = code, onValueChange = { code = it.uppercase() },
                modifier = Modifier.weight(1f), singleLine = true,
                placeholder = { Text("쿠폰 코드", color = TL.faint) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                    focusedBorderColor = TL.jade, unfocusedBorderColor = TL.hairline, cursorColor = TL.jade),
            )
            val enabled = !busy && code.isNotBlank()
            Box(
                Modifier.background(if (enabled) TL.jade else TL.raised, TL.cornerM)
                    .clickable(enabled = enabled) {
                        busy = true
                        scope.launch {
                            try {
                                val days = AccountStore.redeemCoupon(code)
                                android.widget.Toast.makeText(context,
                                    "${days}일 이용권이 적용됐어요 🎉", android.widget.Toast.LENGTH_LONG).show()
                                code = ""
                            } catch (e: Exception) {
                                android.widget.Toast.makeText(context,
                                    e.message ?: "쿠폰 사용에 실패했어요", android.widget.Toast.LENGTH_LONG).show()
                            } finally { busy = false }
                        }
                    }
                    .padding(horizontal = 18.dp, vertical = 15.dp),
            ) {
                Text(if (busy) "확인 중…" else "적용",
                    color = if (enabled) TL.ink else TL.muted, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/** 점수 원장 */
@Composable
fun LedgerScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    val events by db.scores().allFlow(AccountStore.currentUserID).collectAsState(initial = emptyList())

    Column(Modifier.fillMaxSize().background(TL.ink).padding(20.dp)) {
        TLScreenHeader("점수 원장", onBack = onBack)
        androidx.compose.foundation.lazy.LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(events.size) { i ->
                val e = events[i]
                TLCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(e.type.title, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            e.note?.let { Text(it, color = TL.faint, fontSize = 12.sp) }
                            // 12시간제로 통일 (iOS 점수 원장 .shortened 표기 기준)
                            Text("${java.text.SimpleDateFormat("M월 d일", java.util.Locale.KOREA)
                                .format(java.util.Date(e.timestamp))} ${TLFormat.clock(e.timestamp)}",
                                color = TL.faint, fontSize = 11.sp)
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


/** 프라이버시 — 촬영본·데이터 처리 요약 (iOS 프라이버시 화면 대응) */
@Composable
fun PrivacyScreen(onBack: () -> Unit) {
    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        TLScreenHeader("프라이버시", onBack = onBack)
        TLCard {
            Text("📷  촬영본은 내 기기에만", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text("타임랩스 영상은 서버로 전송되지 않고 이 기기에만 저장돼요. 세션 종료 화면에서 저장하지 않으면 자동으로 삭제됩니다.",
                color = TL.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Text("🧠  자리비움 감지도 기기 안에서", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text("사람 감지는 온디바이스 AI로만 처리되며 프레임이 외부로 나가지 않아요.",
                color = TL.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Text("🗂  수집하는 정보", color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text("계정 기능을 위한 이메일·이름, 그리고 상점·벌점 기록뿐이에요. 자세한 내용은 개인정보처리방침을 확인하세요.",
                color = TL.muted, fontSize = 13.sp)
        }
    }
}
