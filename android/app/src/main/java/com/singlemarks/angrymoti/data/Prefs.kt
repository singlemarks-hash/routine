package com.singlemarks.angrymoti.data

import android.content.Context
import android.content.SharedPreferences

/**
 * 가벼운 동기 설정 저장소.
 * 알람 리시버·서비스 등 코루틴 밖에서도 읽어야 해서 DataStore 대신 SharedPreferences를 쓴다.
 */
object Prefs {
    private lateinit var sp: SharedPreferences

    fun init(context: Context) {
        sp = context.getSharedPreferences("angrymoti", Context.MODE_PRIVATE)
    }

    // 온보딩은 '앱/기기 최초 안내'라 기기 전역이 맞다 (계정별 아님).
    var onboarded: Boolean
        get() = sp.getBoolean("onboarded", false)
        set(v) = sp.edit().putBoolean("onboarded", v).apply()

    /** 강도는 계정별(#19) — 공유 기기에서 A의 미친맛 설정이 B에게 새지 않도록 owner로 분리 */
    fun intensityRaw(owner: String): String = sp.getString("intensity.$owner", "spicy") ?: "spicy"
    fun setIntensityRaw(owner: String, v: String) = sp.edit().putString("intensity.$owner", v).apply()

    /** 하향 예약: 다음날 0시 이후 적용 (epoch millis, 0 = 없음) — 강도와 함께 계정별(#19) */
    fun pendingDowngradeAt(owner: String): Long = sp.getLong("pendingDowngradeAt.$owner", 0L)
    fun setPendingDowngradeAt(owner: String, v: Long) =
        sp.edit().putLong("pendingDowngradeAt.$owner", v).apply()

    /** 진행 중 세션 복구용 */
    var activeSessionId: String?
        get() = sp.getString("activeSessionId", null)
        set(v) = sp.edit().putString("activeSessionId", v).apply()

    var breakDeadline: Long
        get() = sp.getLong("breakDeadline", 0L)
        set(v) = sp.edit().putLong("breakDeadline", v).apply()

    /** 슬롯 보너스 최고 지급 단계 (계정별) */
    fun slotBonusAwardedTier(owner: String) = sp.getInt("slotBonus.awardedTier.$owner", 0)
    fun setSlotBonusAwardedTier(owner: String, tier: Int) =
        sp.edit().putInt("slotBonus.awardedTier.$owner", tier).apply()

    /** 미친 매운맛 해제 보너스 지급 여부 (계정당 평생 1회) */
    fun unlockBonusAwarded(owner: String) = sp.getBoolean("unlockBonus.awarded.$owner", false)
    fun setUnlockBonusAwarded(owner: String) =
        sp.edit().putBoolean("unlockBonus.awarded.$owner", true).apply()

    /** 홈 다짐/목표 문구 (계정별) — 크로스 기기 동기화용 수정 시각 동반 */
    fun homeGoal(owner: String) = sp.getString("homeGoal.$owner", "") ?: ""
    fun homeGoalUpdatedAt(owner: String) = sp.getLong("homeGoalUpdatedAt.$owner", 0L)
    fun setHomeGoal(owner: String, text: String, updatedAt: Long = System.currentTimeMillis()) =
        sp.edit().putString("homeGoal.$owner", text)
            .putLong("homeGoalUpdatedAt.$owner", updatedAt).apply()

    /** 게스트/오프라인 계정 표시 이름 */
    var guestName: String?
        get() = sp.getString("guestName", null)
        set(v) = sp.edit().putString("guestName", v).apply()

    // ── 앱 후기 요청 (완주 N회 후 1회 노출) — 기기 전역
    private var reviewCount: Int
        get() = sp.getInt("reviewCompletionCount", 0)
        set(v) = sp.edit().putInt("reviewCompletionCount", v).apply()
    var reviewAsked: Boolean
        get() = sp.getBoolean("reviewAsked", false)
        set(v) = sp.edit().putBoolean("reviewAsked", v).apply()

    /** 완주 성공 시 호출. 임계치(3회) 도달 & 미요청이면 true(리뷰 유도 표시) 반환. */
    fun registerCompletionAndShouldAskReview(): Boolean {
        if (reviewAsked) return false
        val n = reviewCount + 1
        reviewCount = n
        if (n >= 3) { reviewAsked = true; return true }
        return false
    }
}
