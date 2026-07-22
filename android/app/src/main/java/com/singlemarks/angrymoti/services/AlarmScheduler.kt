package com.singlemarks.angrymoti.services

import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.singlemarks.angrymoti.MainActivity
import com.singlemarks.angrymoti.data.AppDb
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * 예약 알람 — AlarmManager 정확 알람 + 풀스크린 알림.
 * 각 활성 예약의 '다음 발생 1건'만 걸고, 울리거나 재부팅되면 다시 건다.
 */
object AlarmScheduler {
    const val CHANNEL_ALARM = "alarm"
    const val CHANNEL_STATUS = "status"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var alarmPlayer: MediaPlayer? = null
    private var chimePlayer: MediaPlayer? = null

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALARM, "활동 알람", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "예약한 활동 시각의 알람"
                setSound(null, null)   // 사운드는 앱이 알람 스트림으로 직접 재생 (무음 모드 관통)
                enableVibration(true)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_STATUS, "세션 상태", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    /** 현재 계정의 모든 활성 예약에 대해 다음 발생 알람을 다시 건다 (액티비티에서 호출 — fire&forget) */
    fun rescheduleAll(context: Context) {
        scope.launch { rescheduleAllNow(context) }
    }

    /** 재등록 후 완료 콜백을 부른다 — 리시버가 goAsync().finish()로 프로세스 조기 종료를 막도록.
     *  (BroadcastReceiver는 onReceive 반환 즉시 프로세스가 죽을 수 있어 DB 작업이 유실될 수 있다) */
    fun rescheduleAllAsync(context: Context, onDone: () -> Unit) {
        scope.launch {
            try { rescheduleAllNow(context) } finally { onDone() }
        }
    }

    private suspend fun rescheduleAllNow(context: Context) {
        val owner = AccountStore.currentUserID
        val reservations = AppDb.get(context).reservations().active(owner)
        for (r in reservations) {
            val fire = r.nextOccurrence() ?: continue
            scheduleExact(context, r.id, fire)
        }
    }

    @SuppressLint("MissingPermission")
    fun scheduleExact(context: Context, reservationId: String, fireAt: Long) {
        val am = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, AlarmReceiver::class.java)
            .putExtra("reservationId", reservationId)
            .putExtra("fireAt", fireAt)
        val pi = PendingIntent.getBroadcast(
            context, reservationId.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // 정확 알람 권한이 없으면(API 31~32에서 사용자 회수 가능) 조용히 버리지 않고
        // 부정확이라도 반드시 건다 — setAndAllowWhileIdle는 Doze 중에도 발화한다(창이 다소 넓어질 뿐).
        if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
            return
        }
        am.setAlarmClock(AlarmManager.AlarmClockInfo(fireAt, pi), pi)
    }

    /** 정확 알람을 걸 수 있는가 (API 31~32에서만 회수 가능, 33+는 USE_EXACT_ALARM으로 항상 true) */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    }

    /** 정확 알람 권한 요청 화면 — 설정/온보딩에서 사용자에게 안내할 때 연다 */
    fun openExactAlarmSettings(context: Context) {
        if (Build.VERSION.SDK_INT >= 31) runCatching {
            context.startActivity(
                Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    android.net.Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    fun cancel(context: Context, reservationId: String) {
        val intent = Intent(context, AlarmReceiver::class.java)
        val pi = PendingIntent.getBroadcast(
            context, reservationId.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        context.getSystemService(AlarmManager::class.java).cancel(pi)
    }

    /** 알람 발화 → 풀스크린 알림 (잠금 화면 위로 알람 화면을 띄운다) */
    fun showAlarmNotification(context: Context, reservationId: String, fireAt: Long) {
        val full = Intent(context, MainActivity::class.java).apply {
            action = "alarm"
            putExtra("reservationId", reservationId)
            putExtra("fireAt", fireAt)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val fullPi = PendingIntent.getActivity(
            context, 1, full, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ALARM)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("활동 시간!")
            .setContentText("알람을 끄는 유일한 방법은 촬영 시작입니다.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(fullPi, true)
            .setContentIntent(fullPi)
            .setOngoing(true)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(1001, n)
    }

    fun cancelAlarmNotification(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(1001)
    }

    fun postStatus(context: Context, id: Int, title: String, body: String) {
        val n = NotificationCompat.Builder(context, CHANNEL_STATUS)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .build()
        context.getSystemService(NotificationManager::class.java).notify(id, n)
    }

    // MARK: 사운드 — USAGE_ALARM 스트림이라 미디어 볼륨·무음 모드와 무관하게 울린다

    fun startAlarmSound(context: Context) {
        if (alarmPlayer != null) return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: return
        // prepare()는 일부 기기/코덱에서 예외를 던질 수 있다 — 알람 화면 진입 크래시를 막기 위해 가드.
        runCatching {
            alarmPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                )
                setDataSource(context, uri)
                isLooping = true
                prepare(); start()
            }
        }.onFailure {
            android.util.Log.e("AngryMoti", "startAlarmSound 실패", it)
            runCatching { alarmPlayer?.release() }
            alarmPlayer = null
        }
    }

    fun stopAlarmSound() {
        alarmPlayer?.run { runCatching { stop() }; release() }
        alarmPlayer = null
    }

    /** 세션 중 알림차단 (iOS muteAllNotifications) — 켜져 있으면 차임 무음 */
    @Volatile var sessionMuted = false

    // ── 시스템 방해 금지(DND) — 안드로이드는 권한만 받으면 앱이 직접 켜고 끌 수 있다
    /** 이번 세션에서 우리가 켠 것인지 (세션 종료 시 자동 해제용) */
    @Volatile var dndEnabledByApp = false

    fun hasDndAccess(context: Context): Boolean =
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager)
            .isNotificationPolicyAccessGranted

    /** 방해 금지 켜기/끄기 — 권한 없으면 false */
    fun setDnd(context: Context, on: Boolean): Boolean {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (!nm.isNotificationPolicyAccessGranted) return false
        nm.setInterruptionFilter(
            if (on) android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY
            else android.app.NotificationManager.INTERRUPTION_FILTER_ALL
        )
        dndEnabledByApp = on
        return true
    }

    /** 세션이 켰던 방해 금지를 세션 종료 시 원복 */
    fun restoreDndIfNeeded(context: Context) {
        if (dndEnabledByApp) { setDnd(context, false); dndEnabledByApp = false }
    }

    /** 방해 금지 접근 권한 설정 화면 열기 */
    fun openDndAccessSettings(context: Context) {
        runCatching {
            context.startActivity(
                Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** 앱 자체 경고음(1분 전 예고·자리비움) — iOS의 '띵동'과 동일한 의도적 알림 사운드.
     *  sessionMuted/시스템 DND는 '외부 알림'을 막는 기능이지 앱 자체 경고까지 막는 게 아니므로,
     *  USAGE_ALARM으로 재생해 방해 금지 상태에서도 반드시 들리게 한다. */
    fun playChime(context: Context) {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: return
        chimePlayer?.release()
        runCatching {
            chimePlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                )
                setDataSource(context, uri)
                setOnCompletionListener { it.release(); if (chimePlayer == it) chimePlayer = null }
                prepare(); start()
            }
        }.onFailure {
            android.util.Log.e("AngryMoti", "playChime 실패", it)
            runCatching { chimePlayer?.release() }
            chimePlayer = null
        }
    }
}
