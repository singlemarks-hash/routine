package com.singlemarks.angrymoti

import android.app.Application
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.AlarmScheduler
import com.singlemarks.angrymoti.services.L10nKeySweep
import com.singlemarks.angrymoti.services.SessionEngine
import com.singlemarks.angrymoti.services.SubscriptionManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class AngryMotiApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        // 레거시 한글 저장값 → 정본 키 1회 재작성 (docs/영어화-설계도.md D3, iOS와 1:1).
        // 멱등이라 이후 동기화·미러와 순서가 엇갈려도 무해하다 (미처 못 바꾼 값은 읽기 호환이 흡수).
        CoroutineScope(Dispatchers.IO).launch { L10nKeySweep.runIfNeeded(this@AngryMotiApp) }
        AccountStore.init(this)
        SessionEngine.init(this)
        SubscriptionManager.init(this)
        AlarmScheduler.createChannels(this)
    }
}
