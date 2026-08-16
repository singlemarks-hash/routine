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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
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
import com.singlemarks.angrymoti.models.ScoreNote
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.Permissions
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.services.SubscriptionManager
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

object Legal {
    private val isKorean get() = java.util.Locale.getDefault().language == "ko"

    /** 약관·개인정보 — 기기 언어에 맞는 노션 하위 페이지로 직행 (iOS Legal.swift 1:1).
     *  스토어 콘솔에는 두 언어를 모두 담은 허브 페이지를 등록한다 — docs/법무-문서-색인.md */
    val TERMS_URL get() = if (isKorean)
        "https://singlemark.notion.site/39f41b10f64b8026ab19cab6bf66ade2"
    else
        "https://singlemark.notion.site/Terms-of-Use-English-3be41b10f64b8016ba06e582c2a03caf"
    val PRIVACY_URL get() = if (isKorean)
        "https://singlemark.notion.site/39f41b10f64b80d2acaffcb5815106a9"
    else
        "https://singlemark.notion.site/Privacy-Policy-English-3be41b10f64b80d99cc8d8ed818fc6ec"

    // 게터인 이유: const는 컴파일 타임 상수만 허용되고, 객체 초기화 시점 캡처는
    // 로케일 전환을 못 따라간다 (Play 필수 자동 갱신 고지 — 임의 수정 금지)
    val SUBSCRIPTION_DISCLOSURE: String
        get() = com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.subscription_disclosure)
}

/** 마이페이지 — 메뉴 허브 */
@Composable
fun MyPageScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var sub by remember { mutableStateOf("menu") }   // menu | profile | paywall | cheer | ledger | privacy | alarmHealth

    // 뒤로가기: 마이페이지 내부 화면에서는 메뉴로 복귀.
    // 메뉴에서는 가로채지 않아 HomeShell의 BackHandler(홈으로 복귀)로 넘어간다.
    BackHandler(enabled = sub != "menu") { sub = "menu" }

    when (sub) {
        "profile" -> { ProfileEditScreen(onBack = { sub = "menu" }, openPaywall = { sub = "paywall" }); return }
        "paywall" -> { PaywallScreen(onBack = { sub = "menu" }); return }
        "cheer" -> { CheerDeveloperScreen(onBack = { sub = "menu" }, openPaywall = { sub = "paywall" }); return }
        "ledger" -> { LedgerScreen(onBack = { sub = "menu" }); return }
        "privacy" -> { PrivacyScreen(onBack = { sub = "menu" }); return }
        "alarmHealth" -> { AlarmHealthScreen(onBack = { sub = "menu" }); return }
    }

    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        // 상단: 원형 뒤로가기 + 중앙 타이틀 (iOS 1:1)
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 24.dp)) {
            TLCircleBack(onClick = onBack)
            Spacer(Modifier.weight(1f))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.my_page), color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f)); Spacer(Modifier.width(44.dp))
        }
        // 아이콘 메뉴 (투명 행) — iOS와 동일 구성
        IconMenuRow(AppIcon.UserRoundCheck, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.profile_subscription)) { sub = "profile" }
        IconMenuRow(AppIcon.Headphones, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.support)) {
            context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:singlemarks@gmail.com")))
        }
        IconMenuRow(AppIcon.Heart, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.support_developer)) { sub = "cheer" }

        androidx.compose.material3.HorizontalDivider(
            color = TL.hairline, modifier = Modifier.padding(vertical = 18.dp))

        // 텍스트 메뉴 (투명 행) — 강도는 활동/그룹별로 각각 설정하므로 전역 강도 탭 제거
        // '알람 점검' — 안드로이드는 알람 실패 경로가 여럿(알림·전체화면·절전·정확알람)이라
        // 사용자가 원인을 스스로 찾을 수 없다. 한 화면에 모아 상태와 해결 버튼을 준다.
        PlainMenuRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.alarm_health)) { sub = "alarmHealth" }
        PlainMenuRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy)) { sub = "privacy" }
        PlainMenuRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.score_ledger)) { sub = "ledger" }
        // D1: 언어 소유권은 OS에 둔다 — 13+(API 33)는 설정 앱의 '앱 언어'로 직행,
        // 그 미만은 앱별 언어가 없어 시스템 언어를 따른다고 안내한다 (iOS 설정 링크와 1:1)
        PlainMenuRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.language_settings)) {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                runCatching {
                    context.startActivity(
                        android.content.Intent(android.provider.Settings.ACTION_APP_LOCALE_SETTINGS,
                            android.net.Uri.parse("package:" + context.packageName)))
                }
            } else {
                android.widget.Toast.makeText(context, com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.language_follows_system),
                    android.widget.Toast.LENGTH_SHORT).show()
            }
        }
        PlainMenuRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.terms_of_use)) { open(Legal.TERMS_URL) }
        PlainMenuRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_policy)) { open(Legal.PRIVACY_URL) }

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
    val profileRestoreMessage = remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val user by AccountStore.user.collectAsState()
    val isPro by SubscriptionManager.isPro.collectAsState()
    val db = remember { AppDb.get(context) }
    val owner = AccountStore.currentUserID
    val events by db.scores().allFlow(owner).collectAsState(initial = emptyList())
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmLogout by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }

    val plus = events.filter { it.points > 0 }.sumOf { it.points }
    val minus = events.filter { it.points < 0 }.sumOf { it.points }

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        TLScreenHeader(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.profile_subscription), onBack = onBack)

        if (user?.provider == "guest") {
            // 게스트 — 로그아웃·계정 삭제·구독은 계정 기능이다. iOS guestCard처럼 로그인 유도만.
            TLCard {
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.guest_mode), color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(6.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.guest_card_body),
                    color = TL.muted, fontSize = 13.sp)
                Spacer(Modifier.height(12.dp))
                TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.create_account_login)) {
                    AccountStore.signOut()   // 게스트 해제 → 로그인 화면으로
                }
            }
            Spacer(Modifier.height(24.dp))
        } else {

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
                    Text(user?.name ?: user?.email ?: androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.member),
                        color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    user?.email?.let { Text(it, color = TL.muted, fontSize = 12.sp) }
                }
                TagChip(when (user?.provider) {
                    "google" -> "Google"; "email" -> androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.email); else -> androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.guest)
                }, selected = false, onClick = {})
            }
            Spacer(Modifier.height(14.dp))
            androidx.compose.material3.HorizontalDivider(color = TL.hairline)
            Spacer(Modifier.height(14.dp))
            Row {
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("+$plus", color = TL.jade, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.my_points), color = TL.muted, fontSize = 12.sp)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("$minus", color = TL.rec, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.my_penalty), color = TL.muted, fontSize = 12.sp)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("${plus + minus}",
                        color = if (plus + minus >= 0) TL.paper else TL.rec,
                        fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.total_score), color = TL.muted, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(10.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.log_out), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                // 오터치 한 번에 로그아웃되지 않도록 확인을 거친다 (iOS 1:1)
                modifier = Modifier.fillMaxWidth().clickable { confirmLogout = true }.padding(6.dp))
        }

        // 구독 카드 — 눈썹 라벨 + 카드(멤버는 raised) + 구독하기/구매 복원 (iOS 1:1)
        Spacer(Modifier.height(18.dp))
        TLEyebrow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.subscription))
        TLCard(raised = isPro) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if (isPro) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership_active) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership),
                        color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        if (isPro) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership_perks_active, SlotPolicy.MEMBER_FLOOR_SLOTS)
                        else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership_perks_pitch, SlotPolicy.MEMBER_FLOOR_SLOTS),
                        color = TL.muted, fontSize = 13.sp)
                }
                if (isPro) {
                    Spacer(Modifier.width(10.dp))   // 설명 문구와 배지가 붙어 보이지 않게
                    androidx.compose.material3.Icon(
                        AppIcon.BadgeCheck,
                        null, tint = TL.jade, modifier = Modifier.size(24.dp))
                }
            }
            if (!isPro) {
                Spacer(Modifier.height(12.dp))
                TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.subscribe), tint = TL.jade, onClick = openPaywall)
            }
            Spacer(Modifier.height(10.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.restore_purchases), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().clickable {
                    SubscriptionManager.refresh { found ->
                        if (!found) profileRestoreMessage.value =
                            com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.restore_not_found)
                    }
                }.padding(4.dp))
        }

        profileRestoreMessage.value?.let { msg ->
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { profileRestoreMessage.value = null },
                containerColor = TL.surface,
                title = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.restore_purchases), color = TL.paper, fontWeight = FontWeight.Black) },
                text = { Text(msg, color = TL.muted) },
                confirmButton = {
                    androidx.compose.material3.TextButton(onClick = { profileRestoreMessage.value = null }) {
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.ok_label), color = TL.rec, fontWeight = FontWeight.Black)
                    }
                },
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(Legal.SUBSCRIPTION_DISCLOSURE, color = TL.faint, fontSize = 11.sp)

        Spacer(Modifier.height(40.dp))
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_account), color = TL.rec, fontSize = 15.sp, fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().background(TL.raised, TL.cornerM)
                .clickable { confirmDelete = true }.padding(vertical = 16.dp))
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_account_note),
            color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
        Spacer(Modifier.height(24.dp))
        }   // 게스트 분기 끝
    }

    if (confirmLogout) {
        AlertDialog(
            onDismissRequest = { confirmLogout = false },
            containerColor = TL.surface,
            title = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.log_out_q), color = TL.paper) },
            text = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.log_out_note), color = TL.muted) },
            confirmButton = {
                TextButton(onClick = {
                    confirmLogout = false
                    AccountStore.signOut()
                }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.log_out), color = TL.rec, fontWeight = FontWeight.Black) }
            },
            dismissButton = {
                TextButton(onClick = { confirmLogout = false }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_short), color = TL.muted) }
            },
        )
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { if (!deleting) confirmDelete = false },
            containerColor = TL.surface,
            title = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.really_delete_q), color = TL.paper) },
            text = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_account_body), color = TL.muted) },
            confirmButton = {
                TextButton(enabled = !deleting, onClick = {
                    deleting = true
                    scope.launch(Dispatchers.IO) {
                        // 삭제 전에 uid를 붙잡아 둔다 — deleteAccount()가 성공하면 로그아웃 상태가
                        // 되어 currentUserID가 "guest"로 바뀌므로, 뒤에 읽으면 엉뚱한 데이터를 지운다.
                        val uid = AccountStore.currentUserID
                        // 서버 삭제를 먼저 확정한다 — 로컬을 먼저 지우면 서버 삭제가 실패했을 때
                        // (재인증 필요 등) 기기 데이터만 사라지고 계정·서버 기록은 남는 반쪽 삭제가 된다.
                        val result = runCatching { AccountStore.deleteAccount() }
                        result.onSuccess {
                            for (s in db.sessions().all(uid)) {
                                CameraRecorder.deleteFiles(context, s.videoFileName, s.thumbnailFileName)
                            }
                            db.reservations().deleteAll(uid)
                            db.sessions().deleteAll(uid)
                            db.scores().deleteAll(uid)
                            withContext(Dispatchers.Main) { deleting = false; confirmDelete = false; onBack() }
                        }.onFailure { e ->
                            withContext(Dispatchers.Main) {
                                deleting = false; confirmDelete = false
                                deleteError = e.message ?: com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.delete_failed_retry)
                            }
                        }
                    }
                }) { Text(if (deleting) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.deleting) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete), color = TL.rec, fontWeight = FontWeight.Black) }
            },
            dismissButton = {
                TextButton(enabled = !deleting, onClick = { confirmDelete = false }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_short), color = TL.muted) }
            },
        )
    }

    deleteError?.let { msg ->
        AlertDialog(
            onDismissRequest = { deleteError = null },
            containerColor = TL.surface,
            title = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_account_failed_title), color = TL.paper) },
            text = { Text(msg, color = TL.muted) },
            confirmButton = {
                TextButton(onClick = { deleteError = null }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.ok_label), color = TL.rec, fontWeight = FontWeight.Black) }
            },
        )
    }
}

// (강도 설정 화면은 제거 — 강도는 활동/그룹별로 각각 설정하는 정책으로 바뀌어
//  전역 강도 메뉴 자체가 사라졌고, 이 화면으로 들어오는 경로가 없었다)

/** 페이월 — 멤버십 (Google Play Billing) */
@Composable
fun PaywallScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val isPro by SubscriptionManager.isPro.collectAsState()
    val product by SubscriptionManager.product.collectAsState()
    val loadingProduct by SubscriptionManager.loadingProduct.collectAsState()
    var restoreMessage by remember { mutableStateOf<String?>(null) }

    // 앱 실행 때 한 번 실패하면 그걸로 끝이었다 — 페이월을 열 때마다 다시 시도한다.
    LaunchedEffect(Unit) { if (SubscriptionManager.product.value == null) SubscriptionManager.queryProduct() }

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
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership), color = TL.paper, fontSize = 24.sp, fontWeight = FontWeight.Black)
        SubscriptionManager.freeTrialLabel?.let { trial ->
            Spacer(Modifier.height(12.dp))
            Text(trial, color = TL.jade, fontSize = 14.sp, fontWeight = FontWeight.Black,
                modifier = Modifier
                    .background(TL.jade.copy(alpha = 0.14f), androidx.compose.foundation.shape.RoundedCornerShape(50))
                    .padding(horizontal = 14.dp, vertical = 6.dp))
        }
        Spacer(Modifier.height(20.dp))
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Benefit(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.benefit_slots, SlotPolicy.MEMBER_FLOOR_SLOTS))
            Benefit(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.benefit_watermark))
            Benefit(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.benefit_insane))
            Benefit(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.benefit_group))
            Benefit(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.benefit_future))
        }
        Spacer(Modifier.height(24.dp))
        if (isPro) {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership_in_use), color = TL.jade, fontSize = 16.sp, fontWeight = FontWeight.Bold)
        } else if (product != null) {
            val label = if (SubscriptionManager.freeTrialLabel != null)
                com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.start_free_then, SubscriptionManager.displayPrice)
            else com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.subscribe_per_month, SubscriptionManager.displayPrice)
            TLPrimaryButton(label, tint = TL.jade) {
                (context as? Activity)?.let { SubscriptionManager.purchase(it) }
            }
        } else if (loadingProduct) {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.loading_subscription), color = TL.faint, fontSize = 13.sp)
        } else {
            // 조회가 끝났는데 상품이 없다 — '불러오는 중'으로 두면 기다리면 될 줄 알고
            // 앱을 껐다 켜는 수밖에 없다 (iOS 1d4a01c와 동일한 정직한 실패 표시)
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.subscription_load_failed),
                color = TL.faint, fontSize = 13.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            TLGhostButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.try_again)) { SubscriptionManager.queryProduct() }
        }
        Spacer(Modifier.height(10.dp))
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.restore_purchases), color = TL.muted, fontSize = 13.sp,
            modifier = Modifier.clickable {
                SubscriptionManager.refresh { found ->
                    if (!found) restoreMessage =
                        com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.restore_not_found_full)
                }
            }.padding(6.dp))

        restoreMessage?.let { msg ->
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { restoreMessage = null },
                containerColor = TL.surface,
                title = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.restore_purchases), color = TL.paper, fontWeight = FontWeight.Black) },
                text = { Text(msg, color = TL.muted) },
                confirmButton = {
                    androidx.compose.material3.TextButton(onClick = { restoreMessage = null }) {
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.ok_label), color = TL.rec, fontWeight = FontWeight.Black)
                    }
                },
            )
        }
        Spacer(Modifier.height(12.dp))
        Text(Legal.SUBSCRIPTION_DISCLOSURE, color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.terms_of_use), color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.TERMS_URL) })
            Text("·", color = TL.faint)
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_policy), color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
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

/** 개발자 응원하기 — 리뷰 유도 + 멤버십 후원 안내 + 문의 */
@Composable
fun CheerDeveloperScreen(onBack: () -> Unit, openPaywall: () -> Unit) {
    val context = LocalContext.current
    fun openReview() {
        val pkg = context.packageName
        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg"))
        val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg"))
        runCatching { context.startActivity(market) }
            .onFailure { runCatching { context.startActivity(web) } }
    }

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        TLScreenHeader(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.support_developer), onBack = onBack)

        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cheer_title), color = TL.paper,
                fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cheer_body),
                color = TL.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        // 별 이모지를 빼면 텍스트가 온전히 가운데로 보인다 — 이모지가 왼쪽에
        // 붙으면 무게중심이 쏠려 가운데 정렬처럼 안 보인다.
        TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.rate_on_play), tint = TL.amber) { openReview() }

        Spacer(Modifier.height(18.dp))
        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.support_more), color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.membership_support_pitch),
                color = TL.muted, fontSize = 13.sp)
            Spacer(Modifier.height(10.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.see_membership), color = TL.jade, fontSize = 14.sp, fontWeight = FontWeight.Black,
                modifier = Modifier.clickable { openPaywall() }.padding(vertical = 4.dp))
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.contact_suggest), color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.email_us), color = TL.jade, fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable {
                    context.startActivity(Intent(Intent.ACTION_SENDTO,
                        Uri.parse("mailto:singlemarks@gmail.com")))
                }.padding(vertical = 4.dp))
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** 점수 원장 */
@Composable
fun LedgerScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    val events by db.scores().allFlow(AccountStore.currentUserID).collectAsState(initial = emptyList())

    // 최근 20건만 — 전건을 다 그리면 반년치 원장에서 스크롤이 무거워지고,
    // iOS 표기(최근 20건 + 강도 병기)와도 어긋난다.
    val recent = events.take(20)

    Column(Modifier.fillMaxSize().background(TL.ink).padding(20.dp)) {
        TLScreenHeader(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.score_ledger), onBack = onBack)
        TLEyebrow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.last_20))
        Spacer(Modifier.height(8.dp))
        if (recent.isEmpty()) {
            TLCard {
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.ledger_empty),
                    color = TL.muted, fontSize = 13.sp)
            }
        }
        androidx.compose.foundation.lazy.LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(recent.size) { i ->
                val e = recent[i]
                TLCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(e.type.title, color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            e.note?.let { Text(ScoreNote.label(it), color = TL.faint, fontSize = 12.sp) }
                            // 12시간제 + 강도 병기 (iOS 점수 원장 표기 기준)
                            Text("${TLFormat.monthDay(e.timestamp)} ${TLFormat.clock(e.timestamp)} · ${e.intensity.title}",
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


/** 프라이버시 — 촬영본·데이터 처리 요약 + 기록 썸네일 전체 삭제 (iOS 프라이버시 화면 대응) */
@Composable
fun PrivacyScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirmDeleteAll by remember { mutableStateOf(false) }
    var deletedToast by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        TLScreenHeader(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy), onBack = onBack)
        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row1_title), color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row1_body),
                color = TL.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row2_title), color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row2_body),
                color = TL.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row3_title), color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row3_body),
                color = TL.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        TLCard {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row4_title), color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_row4_body),
                color = TL.muted, fontSize = 13.sp)
            Spacer(Modifier.height(10.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_all_thumbnails), color = TL.rec, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { confirmDeleteAll = true }.padding(vertical = 4.dp))
        }
    }

    if (confirmDeleteAll) {
        AlertDialog(
            onDismissRequest = { confirmDeleteAll = false },
            containerColor = TL.surface,
            title = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_all_thumbs_q), color = TL.paper) },
            text = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_thumbs_note), color = TL.muted) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDeleteAll = false
                    scope.launch(Dispatchers.IO) {
                        val db = AppDb.get(context)
                        val owner = AccountStore.currentUserID
                        for (s in db.sessions().all(owner)) {
                            if (s.videoFileName == null && s.thumbnailFileName == null) continue
                            CameraRecorder.deleteFiles(context, s.videoFileName, s.thumbnailFileName)
                            db.sessions().upsert(s.copy(videoFileName = null, thumbnailFileName = null))
                        }
                        withContext(Dispatchers.Main) { deletedToast = true }
                    }
                }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.delete_all_keep_records), color = TL.rec, fontWeight = FontWeight.Black) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDeleteAll = false }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_short), color = TL.muted) }
            },
        )
    }
    if (deletedToast) {
        LaunchedEffect(Unit) {
            android.widget.Toast.makeText(context, com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.thumbs_deleted),
                android.widget.Toast.LENGTH_SHORT).show()
            deletedToast = false
        }
    }
}

/**
 * 알람 점검 — "알람이 안 울려요"의 원인을 한 화면에서 확인·해결한다.
 *
 * 안드로이드에서 정시 알람이 실패하는 경로는 권한 하나가 아니다. 알림이 꺼져 있거나,
 * 전체 화면 알림이 막혔거나(API 34+), OEM 절전에 걸려 있으면 각각 다른 방식으로 조용히
 * 실패한다 — 사용자 눈에는 전부 똑같이 "알람이 안 울림"으로 보인다. 그래서 원인별로
 * 상태를 드러내고 해당 설정 화면으로 바로 보낸다.
 */
@Composable
fun AlarmHealthScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    // 설정에 다녀오면 값이 바뀌므로 화면에 돌아올 때마다 다시 읽는다.
    // (composition 1회 캐시하면 '허용했는데 여전히 빨간불'이 된다)
    var refreshKey by remember { mutableStateOf(0) }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) refreshKey++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val notifOk = remember(refreshKey) { Permissions.notificationsEnabled(context) }
    val fullScreenOk = remember(refreshKey) { Permissions.canUseFullScreenAlarm(context) }
    val batteryOk = remember(refreshKey) { Permissions.isBatteryUnrestricted(context) }
    val cameraOk = remember(refreshKey) { Permissions.cameraGranted(context) }
    val exactOk = remember(refreshKey) {
        com.singlemarks.angrymoti.services.AlarmScheduler.canScheduleExact(context)
    }

    Column(Modifier.fillMaxSize().background(TL.ink).verticalScroll(rememberScrollState()).padding(20.dp)) {
        TLScreenHeader(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.alarm_health), onBack = onBack)

        val allOk = notifOk && fullScreenOk && batteryOk && cameraOk && exactOk
        TLNoticeCard(
            if (allOk) AppIcon.CheckCircle else AppIcon.Bell,
            if (allOk) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.alarm_health_ok)
            else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.alarm_health_warn),
            tint = if (allOk) TL.jade else TL.amber,
        )
        Spacer(Modifier.height(16.dp))

        AlarmCheckRow(
            title = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_notif_title),
            detail = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_notif_detail),
            ok = notifOk,
        ) { Permissions.openNotificationSettings(context) }

        AlarmCheckRow(
            title = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_fullscreen_title),
            detail = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_fullscreen_detail),
            ok = fullScreenOk,
        ) { Permissions.openFullScreenAlarmSettings(context) }

        AlarmCheckRow(
            title = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_battery_title),
            detail = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_battery_detail),
            ok = batteryOk,
        ) { Permissions.requestBatteryUnrestricted(context) }

        AlarmCheckRow(
            title = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_exact_title),
            detail = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_exact_detail),
            ok = exactOk,
        ) { com.singlemarks.angrymoti.services.AlarmScheduler.openExactAlarmSettings(context) }

        AlarmCheckRow(
            title = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.camera),
            detail = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.check_camera_detail),
            ok = cameraOk,
        ) {
            // 여기서는 시스템 창을 띄우지 않는다 — 거부 이력이 있으면 창이 뜨지 않아
            // '눌러도 아무 일 없는 버튼'이 된다. 점검 화면은 결과가 확실한 설정으로만 보낸다.
            // (실제 요청은 촬영 시작 시점의 지연 요청이 담당한다)
            Permissions.openAppSettings(context)
        }

        Spacer(Modifier.height(20.dp))
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.samsung_tip),
            color = TL.muted, fontSize = 13.sp, lineHeight = 19.sp)
        Spacer(Modifier.height(40.dp))
    }
}

/** 알람 점검 행 — 상태 점 + 설명 + 해결 버튼 */
@Composable
private fun AlarmCheckRow(title: String, detail: String, ok: Boolean, onFix: () -> Unit) {
    TLCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.Icon(
                if (ok) AppIcon.CheckCircle else AppIcon.CircleEmpty, null,
                tint = if (ok) TL.jade else TL.rec, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(2.dp))
                Text(detail, color = TL.muted, fontSize = 12.sp, lineHeight = 17.sp)
            }
            if (!ok) {
                Spacer(Modifier.width(10.dp))
                TLPillButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.turn_on), tint = TL.rec, onClick = onFix)
            }
        }
    }
    Spacer(Modifier.height(10.dp))
}
