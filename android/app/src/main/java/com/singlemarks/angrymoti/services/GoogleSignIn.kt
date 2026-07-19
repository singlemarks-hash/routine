package com.singlemarks.angrymoti.services

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential

/**
 * Google 로그인 — Credential Manager로 ID 토큰을 받아 AccountStore.signInGoogle에 넘긴다.
 * serverClientId는 Firebase 프로젝트(timelock-eba85)의 웹 OAuth 클라이언트.
 * 기기에 등록된 Google 계정 선택 시트가 뜨며, 취소 시 GetCredentialCancellationException.
 */
object GoogleSignIn {
    private const val WEB_CLIENT_ID =
        "282729232995-njnh0ktbvtqn943qsrh7ge8gbtudo0d9.apps.googleusercontent.com"

    /** 계정 선택 UI를 띄우고 Google ID 토큰을 반환한다. Activity 컨텍스트 필요. */
    suspend fun requestIdToken(activityContext: Context): String {
        val manager = CredentialManager.create(activityContext)
        val option = GetGoogleIdOption.Builder()
            .setFilterByAuthorizedAccounts(false)   // 처음 쓰는 계정도 목록에 표시
            .setServerClientId(WEB_CLIENT_ID)
            .build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val credential = manager.getCredential(activityContext, request).credential
        if (credential is CustomCredential &&
            credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
        ) {
            return GoogleIdTokenCredential.createFrom(credential.data).idToken
        }
        error("Google 계정 정보를 가져오지 못했어요.")
    }
}
