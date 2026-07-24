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
import androidx.compose.foundation.layout.padding
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

    Column(
        modifier = Modifier.fillMaxSize().background(TL.ink)
            .verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // 헤더 — 캐릭터 + 출석부 (iOS 1:1)
        Spacer(Modifier.height(36.dp))
        Image(painterResource(R.drawable.onboarding_character), null, Modifier.size(96.dp))
        Spacer(Modifier.height(20.dp))
        Text("앵그리모티 출석부", color = TL.rec, fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold, letterSpacing = 2.2.sp)
        Spacer(Modifier.height(8.dp))
        Text("기록은 계정에 남습니다", color = TL.paper, fontSize = 26.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(6.dp))
        Text("상점과 벌점은 계정별로 관리됩니다.\n기기를 바꿔도 이력이 따라옵니다.",
            color = TL.muted, fontSize = 14.sp, textAlign = TextAlign.Center, lineHeight = 20.sp)
        Spacer(Modifier.height(28.dp))

        if (pendingEmail != null) {
            // 이메일 인증 대기 패널 — 인증을 마쳐야 입장 가능 (iOS 1:1)
            Column(
                Modifier.fillMaxWidth().background(TL.surface, TL.cornerL).padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("✉️", fontSize = 40.sp)
                Spacer(Modifier.height(12.dp))
                Text("이메일 인증이 필요합니다", color = TL.paper, fontSize = 20.sp,
                    fontWeight = FontWeight.Black)
                Spacer(Modifier.height(6.dp))
                Text("$pendingEmail 로 인증 메일을 보냈습니다.\n메일함에서 인증 링크를 누른 뒤 아래 버튼을 눌러주세요.",
                    color = TL.muted, fontSize = 13.sp, textAlign = TextAlign.Center, lineHeight = 19.sp)
                Spacer(Modifier.height(16.dp))
                TLPrimaryButton(if (busy) "확인 중…" else "인증 완료했어요", enabled = !busy) {
                    scope.launch {
                        busy = true; error = null; info = null
                        runCatching {
                            if (!AccountStore.confirmEmailVerified())
                                error = "아직 인증이 확인되지 않았어요. 메일의 링크를 먼저 눌러주세요."
                        }.onFailure { error = friendlyAuthError(it) }
                        busy = false
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row {
                    TextButton(onClick = {
                        scope.launch {
                            runCatching { AccountStore.resendVerificationEmail() }
                            info = "인증 메일을 다시 보냈습니다. 메일함(스팸함 포함)을 확인하세요."
                        }
                    }) { Text("인증 메일 재발송", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
                    Spacer(Modifier.width(18.dp))
                    TextButton(onClick = { error = null; info = null; AccountStore.cancelPendingVerification() }) {
                        Text("다른 계정으로", color = TL.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
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
                listOf("signin" to "로그인", "signup" to "회원가입").forEach { (key, label) ->
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
                OutlinedTextField(name, { name = it }, label = { Text("이름") },
                    colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
                Spacer(Modifier.height(10.dp))
            }
            OutlinedTextField(email, { email = it.trim() }, label = { Text("이메일") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(password, { password = it },
                label = { Text(if (mode == "signup") "비밀번호 (8자 이상)" else "비밀번호") },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
            if (mode == "signup") {
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(passwordConfirm, { passwordConfirm = it },
                    label = { Text("비밀번호 확인") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
                if (passwordConfirm.isNotEmpty() && password != passwordConfirm) {
                    Text("✕ 비밀번호가 서로 다릅니다", color = TL.rec, fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
                }
                Text("가입하면 입력한 주소로 인증 메일이 발송됩니다.", color = TL.faint, fontSize = 11.sp,
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
                    password.length >= 8 && password == passwordConfirm
            }
            TLPrimaryButton(
                if (busy) "확인 중…" else if (mode == "signin") "로그인" else "회원가입",
                enabled = !busy && formReady,
            ) {
                scope.launch {
                    busy = true; error = null
                    runCatching {
                        if (mode == "signin") AccountStore.signInEmail(email, password)
                        else AccountStore.signUpEmail(email, password, name.trim())
                    }.onFailure {
                        error = if (!AccountStore.firebaseAvailable)
                            "서버 미연동 상태예요. 게스트 모드로 시작해보세요." else friendlyAuthError(it)
                    }
                    busy = false
                }
            }

            // ── 또는 ──
            Row(Modifier.fillMaxWidth().padding(vertical = 22.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f).height(1.dp).background(TL.hairline))
                Text("또는", color = TL.faint, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 12.dp))
                Box(Modifier.weight(1f).height(1.dp).background(TL.hairline))
            }

            if (AccountStore.firebaseAvailable) {
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
                Spacer(Modifier.height(26.dp))
            }

            // 게스트 — 텍스트 버튼 (iOS 1:1)
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.clickable(enabled = !busy) { AccountStore.continueAsGuest(null) },
            ) {
                Text("게스트로 시작", color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text("기록이 이 기기에만 저장됩니다 · 나중에 로그인하면 계정으로 옮겨집니다",
                    color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 3.dp))
            }
        }

        // 약관 동의 고지 + 링크 (iOS 1:1)
        Text("계속하면 이용약관과 개인정보처리방침에 동의하는 것으로 간주됩니다.",
            color = TL.faint, fontSize = 11.sp, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 18.dp))
        Row(Modifier.padding(top = 8.dp, bottom = 24.dp)) {
            Text("이용약관", color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.TERMS_URL) })
            Text(" · ", color = TL.faint, fontSize = 12.sp)
            Text("개인정보처리방침", color = TL.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { open(Legal.PRIVACY_URL) })
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
        Text("Google로 계속하기", color = TL.ink, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

private fun friendlyAuthError(t: Throwable): String {
    if (t is androidx.credentials.exceptions.NoCredentialException)
        return "기기에 등록된 Google 계정이 없어요. 설정 → 계정에서 Google 계정을 추가한 뒤 다시 시도해주세요."
    val m = t.message ?: return "오류가 발생했어요. 잠시 후 다시 시도해주세요."
    return when {
        m.contains("badly formatted") -> "이메일 형식이 올바르지 않아요."
        m.contains("password is invalid") || m.contains("INVALID_LOGIN_CREDENTIALS") ->
            "이메일 또는 비밀번호가 맞지 않아요."
        m.contains("already in use") -> "이미 가입된 이메일이에요. 로그인해주세요."
        m.contains("at least 6 characters") -> "비밀번호는 8자 이상으로 설정해주세요."
        m.contains("network") -> "네트워크 연결을 확인해주세요."
        else -> m
    }
}
