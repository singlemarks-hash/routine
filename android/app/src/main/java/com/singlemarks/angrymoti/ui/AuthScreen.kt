package com.singlemarks.angrymoti.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.singlemarks.angrymoti.R
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.GoogleSignIn
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.launch

/**
 * 출석부 — 로그인/회원가입 (iOS AuthView 1:1).
 * 이메일(인증 필수) · Google · 게스트. 회원가입은 비밀번호 8자 이상 + 확인 일치 + 메일 인증.
 */
/** 회원가입 비밀번호 최소 길이 — 라벨·검증·오류 매핑이 모두 이 값을 쓴다 */
private const val PASSWORD_MIN_LENGTH = 8

@Composable
fun AuthScreen() {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val pendingEmail by AccountStore.pendingVerificationEmail.collectAsState()
    var mode by remember { mutableStateOf("signin") }   // signin | signup
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var passwordConfirm by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var info by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    fun open(url: String) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }

    // 배경은 스크롤 콘텐츠가 아니라 화면에 고정한다 — 스크롤되는 Column에 직접 걸면
    // 그라디언트가 콘텐츠 전체 높이에 늘어나 화면에서 본 비율과 달라진다.
    Box(Modifier.fillMaxSize().background(TL.ink)) {
        // 상단에서 아래로 옅어지는 레드 글로우 — 온보딩(하단→상단)과 반대 방향.
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to TL.rec.copy(alpha = 0.28f),
                    0.35f to TL.rec.copy(alpha = 0.10f),
                    0.7f to Color.Transparent,
                )
            )
        )
    Column(
        modifier = Modifier.fillMaxSize()
            .statusBarsPadding().navigationBarsPadding()
            .verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // 헤더 — 좌측 정렬 카피 (iOS 1:1, 캐릭터·출석부 문구는 제거)
        Spacer(Modifier.height(56.dp))
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.Start) {
            // 강제 줄바꿈(\n) 대신 자연 줄바꿈 — 온보딩과 같은 이유(갤럭시 노트20 등
            // 유효 폭이 좁은 기기에서 단어 하나가 홀로 다음 줄로 밀리는 문제 방지).
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.auth_headline), color = TL.paper, fontSize = 26.sp,
                fontWeight = FontWeight.Black, lineHeight = 33.sp)
            Spacer(Modifier.height(14.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.auth_sub),
                color = TL.muted, fontSize = 14.sp, lineHeight = 20.sp)
        }
        Spacer(Modifier.height(28.dp))

        if (pendingEmail != null) {
            // 이메일 인증 대기 패널 — 인증을 마쳐야 입장 가능 (iOS 1:1)
            Column(
                Modifier.fillMaxWidth().background(TL.surface, TL.cornerL).padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("✉️", fontSize = 40.sp)
                Spacer(Modifier.height(12.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.email_verification_needed), color = TL.paper, fontSize = 20.sp,
                    fontWeight = FontWeight.Black)
                Spacer(Modifier.height(6.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.verification_sent, pendingEmail ?: ""),
                    color = TL.muted, fontSize = 13.sp, textAlign = TextAlign.Center, lineHeight = 19.sp)
                Spacer(Modifier.height(16.dp))
                TLPrimaryButton(if (busy) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.checking) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.ive_verified), enabled = !busy) {
                    scope.launch {
                        busy = true; error = null; info = null
                        runCatching {
                            if (!AccountStore.confirmEmailVerified())
                                error = com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.not_verified_yet)
                        }.onFailure { error = friendlyAuthError(it) }
                        busy = false
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row {
                    TextButton(onClick = {
                        scope.launch {
                            runCatching { AccountStore.resendVerificationEmail() }
                            info = com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.verification_resent)
                        }
                    }) { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.resend_verification), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
                    Spacer(Modifier.width(18.dp))
                    TextButton(onClick = { error = null; info = null; AccountStore.cancelPendingVerification() }) {
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.use_different_account), color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            info?.let {
                Text(it, color = TL.amber, fontSize = 13.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 12.dp))
            }
            error?.let {
                Text("⚠️ $it", color = TL.rec, fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp))
            }
        } else {
            // 로그인 | 회원가입 캡슐 토글 (iOS 1:1)
            Row(
                Modifier.fillMaxWidth().background(TL.surface, CircleShape)
                    .border(1.dp, TL.hairline, CircleShape).padding(4.dp),
            ) {
                listOf("signin" to androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.log_in), "signup" to androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.sign_up)).forEach { (key, label) ->
                    Box(
                        Modifier.weight(1f)
                            .background(if (mode == key) TL.paper else Color.Transparent, CircleShape)
                            .clickable { mode = key; error = null }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(label, color = if (mode == key) TL.ink else TL.muted,
                            fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            Spacer(Modifier.height(16.dp))

            val fieldColors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline,
                focusedLabelColor = TL.muted, unfocusedLabelColor = TL.faint,
                cursorColor = TL.rec,
            )
            if (mode == "signup") {
                OutlinedTextField(name, { name = it }, label = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.name)) },
                    colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
                Spacer(Modifier.height(10.dp))
            }
            OutlinedTextField(email, { email = it.trim() }, label = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.email)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(password, { password = it },
                label = { Text(if (mode == "signup") androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.password_min, PASSWORD_MIN_LENGTH) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.password)) },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
            if (mode == "signup") {
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(passwordConfirm, { passwordConfirm = it },
                    label = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.confirm_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
                if (passwordConfirm.isNotEmpty() && password != passwordConfirm) {
                    Text("✕ " + androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.passwords_differ), color = TL.rec, fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
                }
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.verification_will_send), color = TL.faint, fontSize = 11.sp,
                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
            }
            Spacer(Modifier.height(16.dp))

            error?.let {
                Text("⚠️ $it", color = TL.rec, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp))
            }

            val formReady = if (mode == "signin") {
                email.isNotBlank() && password.isNotEmpty()
            } else {
                name.isNotBlank() && email.isNotBlank() &&
                    password.length >= PASSWORD_MIN_LENGTH && password == passwordConfirm
            }
            TLPrimaryButton(
                if (busy) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.checking) else if (mode == "signin") androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.log_in) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.sign_up),
                enabled = !busy && formReady,
            ) {
                scope.launch {
                    busy = true; error = null
                    runCatching {
                        if (mode == "signin") AccountStore.signInEmail(email, password)
                        else AccountStore.signUpEmail(email, password, name.trim())
                    }.onFailure {
                        error = if (!AccountStore.firebaseAvailable)
                            com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.server_not_connected) else friendlyAuthError(it)
                    }
                    busy = false
                }
            }

            // 비밀번호 찾기 — 로그인 모드에서만 (iOS 1:1)
            if (mode == "signin") {
                Spacer(Modifier.height(14.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.forgot_password), color = TL.paper, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable(enabled = !busy) {
                        scope.launch {
                            busy = true; error = null; info = null
                            runCatching { AccountStore.sendPasswordReset(email) }
                                .onSuccess {
                                    info = com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.reset_email_sent)
                                }
                                .onFailure { error = friendlyAuthError(it) }
                            busy = false
                        }
                    })
            }
            info?.let {
                Text(it, color = TL.jade, fontSize = 13.sp, modifier = Modifier.padding(top = 10.dp))
            }

            // ── 또는 ──
            Row(Modifier.fillMaxWidth().padding(vertical = 22.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f).height(1.dp).background(TL.hairline))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.or_divider), color = TL.faint, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 12.dp))
                Box(Modifier.weight(1f).height(1.dp).background(TL.hairline))
            }

            // 게스트를 구글보다 먼저 — iOS 1:1 순서. 서브텍스트는 뺐다(과한 설명).
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.continue_as_guest), color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth()
                    .clickable(enabled = !busy) { AccountStore.continueAsGuest(null) }
                    .padding(vertical = 4.dp))

            if (AccountStore.firebaseAvailable) {
                Spacer(Modifier.height(20.dp))
                GoogleButton(enabled = !busy) {
                    scope.launch {
                        busy = true; error = null
                        runCatching {
                            val token = GoogleSignIn.requestIdToken(context)
                            AccountStore.signInGoogle(token)
                        }.onFailure {
                            if (it !is GetCredentialCancellationException)
                                error = friendlyAuthError(it)
                        }
                        busy = false
                    }
                }
            }
        }

        // 약관 동의 고지 + 링크 (iOS 1:1)
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.all_recordings_local),
            color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 18.dp))
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.agree_terms),
            color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp))
        Row(Modifier.padding(top = 8.dp, bottom = 24.dp)) {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.terms_of_use), color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.TERMS_URL) })
            Text(" · ", color = TL.faint, fontSize = 12.sp)
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.privacy_policy), color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.PRIVACY_URL) })
        }
    }
    }
}

/** Google 로그인 버튼 — 흰 배경 + 공식 G 로고 + 텍스트 (Google 브랜드 가이드 라이트 버튼) */
@Composable
private fun GoogleButton(enabled: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (enabled) Color.White else Color.White.copy(alpha = 0.5f), TL.cornerM)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        androidx.compose.foundation.Image(
            painter = androidx.compose.ui.res.painterResource(R.drawable.ic_google_logo),
            contentDescription = null,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.continue_with_google), color = TL.ink, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

private fun friendlyAuthError(t: Throwable): String {
    if (t is androidx.credentials.exceptions.NoCredentialException)
        return com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.no_google_account)
    val m = t.message ?: return com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.generic_error)
    return when {
        m.contains("badly formatted") -> com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.invalid_email)
        m.contains("password is invalid") || m.contains("INVALID_LOGIN_CREDENTIALS") ->
            com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.wrong_credentials)
        m.contains("already in use") -> com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.email_in_use)
        m.contains("at least 6 characters") -> com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.password_too_short, PASSWORD_MIN_LENGTH)
        m.contains("network") -> com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.check_network)
        else -> m
    }
}
