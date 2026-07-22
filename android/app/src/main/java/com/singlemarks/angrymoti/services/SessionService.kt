package com.singlemarks.angrymoti.services

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.singlemarks.angrymoti.MainActivity

/**
 * 촬영 중 포그라운드 서비스 — OEM(특히 삼성)의 백그라운드 프로세스 킬로부터
 * 세션·카메라·틱 타이머를 보호한다. 화면 꺼짐 방지용 WakeLock 포함.
 */
class SessionService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = PendingIntent.getActivity(
            this, 10, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val n: Notification = NotificationCompat.Builder(this, AlarmScheduler.CHANNEL_STATUS)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("앵그리모티 촬영 중")
            .setContentText("타임랩스 세션이 진행되고 있습니다.")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(3001, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(3001, n)
        }
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "angrymoti:session").apply {
            setReferenceCounted(false)
            acquire(10 * 60 * 60 * 1000L)   // 최대 세션(8h) + 여유
        }
        // START_NOT_STICKY — 프로세스가 죽으면 세션 상태(SessionEngine)도 사라져 촬영을 이어갈 수
        // 없으므로 서비스를 부활시키지 않는다. START_STICKY면 세션 없이 서비스만 되살아나
        // '촬영 중' 알림 + 웨이크락이 좀비로 남아 배터리를 갉아먹는다(#14). 정상 종료 시엔
        // cleanupRuntime이 stop()을 호출하고, 비정상 종료분은 앱 재실행 때 recoverOrphan이 기록한다.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.release(); wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        fun start(context: Context) {
            context.startForegroundService(Intent(context, SessionService::class.java))
        }
        fun stop(context: Context) {
            context.stopService(Intent(context, SessionService::class.java))
        }
    }
}
