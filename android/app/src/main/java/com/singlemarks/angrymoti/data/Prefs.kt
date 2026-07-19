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

    var onboarded: Boolean
        get() = sp.getBoolean("onboarded", false)
        set(v) = sp.edit().putBoolean("onboarded", v).apply()

    var intensityRaw: String
        get() = sp.getString("intensity", "spicy") ?: "spicy"
        set(v) = sp.edit().putString("intensity", v).apply()

    /** 하향 예약: 다음날 0시 이후 적용 (epoch millis of 적용 시각, 0 = 없음) */
    var pendingDowngradeAt: Long
        get() = sp.getLong("pendingDowngradeAt", 0L)
        set(v) = sp.edit().putLong("pendingDowngradeAt", v).apply()

    /** 진행 중 세션 복구용 */
    var activeSessionId: String?
        get() = sp.getString("activeSessionId", null)
        set(v) = sp.edit().putString("activeSessionId", v).apply()

    var breakDeadline: Long
        get() = sp.getLong("breakDeadline", 0L)
        set(v) = sp.edit().putLong("breakDeadline", v).apply()

    var callActive: Boolean
        get() = sp.getBoolean("callActive", false)
        set(v) = sp.edit().putBoolean("callActive", v).apply()

    /** 슬롯 보너스 최고 지급 단계 (계정별) */
    fun slotBonusAwardedTier(owner: String) = sp.getInt("slotBonus.awardedTier.$owner", 0)
    fun setSlotBonusAwardedTier(owner: String, tier: Int) =
        sp.edit().putInt("slotBonus.awardedTier.$owner", tier).apply()

    /** 미친 매운맛 해제 보너스 지급 여부 (계정당 평생 1회) */
    fun unlockBonusAwarded(owner: String) = sp.getBoolean("unlockBonus.awarded.$owner", false)
    fun setUnlockBonusAwarded(owner: String) =
        sp.edit().putBoolean("unlockBonus.awarded.$owner", true).apply()

    /** 홈 다짐/목표 문구 (계정별) */
    fun homeGoal(owner: String) = sp.getString("homeGoal.$owner", "") ?: ""
    fun setHomeGoal(owner: String, text: String) =
        sp.edit().putString("homeGoal.$owner", text).apply()

    /** 게스트/오프라인 계정 표시 이름 */
    var guestName: String?
        get() = sp.getString("guestName", null)
        set(v) = sp.edit().putString("guestName", v).apply()
}
