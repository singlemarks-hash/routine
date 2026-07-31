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
        // camera 타입 FGS는 CAMERA 권한이 없으면 시작 자체가 SecurityException이다(API 34+).
        // 여기서 던지면 촬영 중에 앱이 통째로 죽으므로, 잡아서 서비스만 접는다 —
        // 세션(SessionEngine)은 그대로 돌고, 잃는 건 OEM 킬 방어와 웨이크락뿐이다.
        val started = runCatching {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(3001, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            } else {
                startForeground(3001, n)
            }
        }.isSuccess
        if (!started) {
            android.util.Log.e("AngryMoti", "SessionService: 포그라운드 시작 실패 — 서비스 없이 진행")
            stopSelf()
            return START_NOT_STICKY
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
            // 1차 방어 — 카메라 권한 없이 camera 타입 FGS를 시작하면 API 34+에서 SecurityException.
            // UI(거치 가이드)에서도 막고 있지만 그건 화면 한 곳의 방어라, 진입 경로가 하나만
            // 늘어도 크래시가 된다. 서비스를 켜는 쪽에서 한 번 더 본다.
            if (!Permissions.cameraGranted(context)) {
                android.util.Log.e("AngryMoti", "SessionService.start: CAMERA 권한 없음 — 시작 보류")
                return
            }
            runCatching {
                context.startForegroundService(Intent(context, SessionService::class.java))
            }.onFailure {
                // ForegroundServiceStartNotAllowedException 등 — 서비스는 포기하되 세션은 잇는다
                android.util.Log.e("AngryMoti", "SessionService.start 실패: ${it.message}")
            }
        }
        fun stop(context: Context) {
            context.stopService(Intent(context, SessionService::class.java))
        }
    }
}
