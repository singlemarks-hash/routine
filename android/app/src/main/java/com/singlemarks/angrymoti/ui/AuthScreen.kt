package com.singlemarks.angrymoti.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.singlemarks.angrymoti.R
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.GoogleSignIn
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.launch

/** 로그인 — 이메일(인증 필수)/게스트. Google은 Firebase 연동 후 활성화. */
@Composable
fun AuthScreen() {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val pendingEmail by AccountStore.pendingVerificationEmail.collectAsState()
    var mode by remember { mutableStateOf("signin") }   // signin | signup
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxSize().background(TL.ink)
            .verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(40.dp))
        Image(painterResource(R.drawable.onboarding_character), null, Modifier.size(96.dp))
        Spacer(Modifier.height(12.dp))
        Text("앵그리모티", color = TL.paper, fontSize = 26.sp, fontWeight = FontWeight.Black)
        Text("상점·벌점은 계정 단위로 기록됩니다", color = TL.muted, fontSize = 13.sp)
        Spacer(Modifier.height(28.dp))

        if (pendingEmail != null) {
            TLCard {
                Text("이메일 인증 대기 중", color = TL.paper, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Spacer(Modifier.height(6.dp))
                Text("$pendingEmail 으로 인증 메일을 보냈어요.\n메일의 링크를 누른 뒤 아래 버튼을 눌러주세요.",
                    color = TL.muted, fontSize = 13.sp)
                Spacer(Modifier.height(14.dp))
                TLPrimaryButton("인증 완료했어요", tint = TL.jade) {
                    scope.launch {
                        busy = true
                        runCatching {
                            if (!AccountStore.confirmEmailVerified()) error = "아직 인증이 확인되지 않았어요. 메일의 링크를 먼저 눌러주세요."
                        }.onFailure { error = it.message }
                        busy = false
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    TextButton(onClick = { scope.launch { runCatching { AccountStore.resendVerificationEmail() } } }) {
                        Text("인증 메일 다시 보내기", color = TL.muted, fontSize = 13.sp)
                    }
                    TextButton(onClick = { AccountStore.cancelPendingVerification() }) {
                        Text("다른 계정으로", color = TL.muted, fontSize = 13.sp)
                    }
                }
            }
        } else {
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
            OutlinedTextField(password, { password = it }, label = { Text("비밀번호 (6자 이상)") },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = fieldColors, modifier = Modifier.fillMaxWidth(), singleLine = true)
            Spacer(Modifier.height(16.dp))

            error?.let {
                Text(it, color = TL.rec, fontSize = 13.sp, modifier = Modifier.padding(bottom = 10.dp))
            }

            TLPrimaryButton(
                if (busy) "처리 중…" else if (mode == "signin") "이메일로 로그인" else "가입하고 인증 메일 받기",
                enabled = !busy && email.isNotBlank() && password.length >= 6 &&
                    (mode == "signin" || name.isNotBlank()),
            ) {
                scope.launch {
                    busy = true; error = null
                    runCatching {
                        if (mode == "signin") AccountStore.signInEmail(email, password)
                        else AccountStore.signUpEmail(email, password, name)
                    }.onFailure {
                        error = if (!AccountStore.firebaseAvailable)
                            "서버 미연동 상태예요. 게스트 모드로 시작해보세요." else friendlyAuthError(it)
                    }
                    busy = false
                }
            }
            Spacer(Modifier.height(10.dp))
            TextButton(onClick = { mode = if (mode == "signin") "signup" else "signin"; error = null }) {
                Text(if (mode == "signin") "계정이 없어요 → 이메일 가입" else "이미 계정이 있어요 → 로그인",
                    color = TL.muted, fontSize = 14.sp)
            }

            Spacer(Modifier.height(22.dp))
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
                Spacer(Modifier.height(10.dp))
            }
            TLGhostButton("게스트로 둘러보기") {
                AccountStore.continueAsGuest(null)
            }
            Text("게스트 기록은 이 기기에만 저장돼요", color = TL.faint, fontSize = 12.sp,
                modifier = Modifier.padding(top = 8.dp))
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** Google 로그인 버튼 — 흰 배경 + 잉크 텍스트 (Google 브랜드 가이드 라이트 버튼) */
@Composable
private fun GoogleButton(enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (enabled) Color.White else Color.White.copy(alpha = 0.5f), TL.cornerM)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text("G  Google로 계속하기", color = TL.ink, fontSize = 16.sp, fontWeight = FontWeight.Bold)
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
        m.contains("network") -> "네트워크 연결을 확인해주세요."
        else -> m
    }
}
