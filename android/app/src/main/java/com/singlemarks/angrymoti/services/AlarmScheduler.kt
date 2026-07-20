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

    /** 현재 계정의 모든 활성 예약에 대해 다음 발생 알람을 다시 건다 */
    fun rescheduleAll(context: Context) {
        scope.launch {
            val owner = AccountStore.currentUserID
            val reservations = AppDb.get(context).reservations().active(owner)
            for (r in reservations) {
                val fire = r.nextOccurrence() ?: continue
                scheduleExact(context, r.id, fire)
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun scheduleExact(context: Context, reservationId: String, fireAt: Long) {
        val am = context.getSystemService(AlarmManager::class.java)
        if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) return
        val intent = Intent(context, AlarmReceiver::class.java)
            .putExtra("reservationId", reservationId)
            .putExtra("fireAt", fireAt)
        val pi = PendingIntent.getBroadcast(
            context, reservationId.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        am.setAlarmClock(AlarmManager.AlarmClockInfo(fireAt, pi), pi)
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
    }

    fun stopAlarmSound() {
        alarmPlayer?.run { runCatching { stop() }; release() }
        alarmPlayer = null
    }

    /** 세션 중 알림차단 (iOS muteAllNotifications) — 켜져 있으면 차임 무음 */
    @Volatile var sessionMuted = false

    fun playChime(context: Context) {
        if (sessionMuted) return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION) ?: return
        chimePlayer?.release()
        chimePlayer = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            )
            setDataSource(context, uri)
            setOnCompletionListener { it.release(); if (chimePlayer == it) chimePlayer = null }
            prepare(); start()
        }
    }
}
