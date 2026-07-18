package com.singlemarks.angrymoti

import android.app.Application
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.AlarmScheduler
import com.singlemarks.angrymoti.services.SessionEngine
import com.singlemarks.angrymoti.services.SubscriptionManager

class AngryMotiApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        AccountStore.init(this)
        SessionEngine.init(this)
        SubscriptionManager.init(this)
        AlarmScheduler.createChannels(this)
    }
}
