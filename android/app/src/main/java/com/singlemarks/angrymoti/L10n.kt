package com.singlemarks.angrymoti

import android.content.Context

/**
 * 비컴포저블 문맥(모델 enum·서비스)에서 문자열 리소스를 푸는 전역 헬퍼 —
 * iOS의 String(localized:)가 어디서나 불리는 것과 1:1 대응.
 * 컴포저블 안에서는 이걸 쓰지 말고 stringResource()를 쓴다(리컴포지션 시 로케일 추적).
 * Application.onCreate 첫 줄에서 init 되므로 이후 어느 시점에 불려도 안전하다.
 */
object L10n {
    private lateinit var appContext: Context
    private var testResolver: ((Int, Array<out Any>) -> String)? = null

    fun init(context: Context) { appContext = context.applicationContext }

    /** JVM 단위 테스트용 — Context가 없으므로 리소스 해석기를 직접 주입한다 (G3 테스트가 values-ko XML로 채운다) */
    @androidx.annotation.VisibleForTesting
    fun initForTest(resolver: (Int, Array<out Any>) -> String) { testResolver = resolver }

    fun str(id: Int, vararg args: Any): String {
        testResolver?.let { return it(id, args) }
        return if (args.isEmpty()) appContext.getString(id) else appContext.getString(id, *args)
    }
}
