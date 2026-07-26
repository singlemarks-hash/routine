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
    /** 예고(-10분)·마지막 경고(+5분) — 알람 본체와 달리 기본 알림음으로 짧게 알린다 */
    const val CHANNEL_REMINDER = "reminder"
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
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_REMINDER, "시작 예고·경고",
                NotificationManager.IMPORTANCE_HIGH).apply {
                description = "활동 10분 전 예고와 미시작 경고"
                enableVibration(true)
            }
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
        val now = System.currentTimeMillis()
        for (r in reservations) {
            val fire = r.nextOccurrence() ?: continue
            scheduleExact(context, r.id, fire)
            // 보조 알람(예고·마지막 경고)은 예약당 PendingIntent 슬롯이 1개다. 대상을
            // '다음 발생'으로만 잡으면, 정각 발화 직후의 재등록(리시버·앱 진입)이 방금
            // 울린 발생의 +5분 경고를 내일 것으로 덮어 지운다 — 3단 에스컬레이션의
            // 마지막 단계가 항상 죽는다. 진행 중일 수 있는 발생(하한 now - 시작창)을
            // 우선 대상으로 잡는다 (iOS imminentOccurrences의 하한과 동일한 이유).
            val imminent = imminentOccurrence(r, now)
            val target = if (imminent != null && imminent + 5 * 60_000L > now) imminent else fire
            // -10분 예고 — 준비 시간을 준다 (iOS pre-alert 1:1)
            val preAt = target - 10 * 60_000L
            if (preAt > now) scheduleKind(context, r.id, target, "prealert", preAt)
            // +5분 마지막 경고 — 발화 시점에 시작 여부를 확인하고 표시한다
            val warnAt = target + 5 * 60_000L
            if (warnAt > now) scheduleKind(context, r.id, target, "lastwarn", warnAt)
        }
    }

    /** 시작 창 안에서 진행 중일 수 있는 발생 — fire ∈ (now - 시작창, now]. 없으면 null.
     *  자정 직후에는 전날 발생이 아직 창 안일 수 있어 어제부터 본다. */
    private fun imminentOccurrence(r: com.singlemarks.angrymoti.data.Reservation, now: Long): Long? {
        val floor = now - com.singlemarks.angrymoti.models.TimePolicy.START_WINDOW_SECONDS * 1000
        val cal = java.util.Calendar.getInstance().apply {
            timeInMillis = now
            set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
            add(java.util.Calendar.DAY_OF_MONTH, -1)
        }
        repeat(2) {
            r.occurrenceOn(cal.timeInMillis)?.let { if (it > floor && it <= now) return it }
            cal.add(java.util.Calendar.DAY_OF_MONTH, 1)
        }
        return null
    }

    /** 예고/경고 보조 알람 — 메인 알람과 다른 requestCode를 써서 서로 덮지 않는다 */
    @SuppressLint("MissingPermission")
    private fun scheduleKind(context: Context, reservationId: String, fireAt: Long,
                             kind: String, triggerAt: Long) {
        val am = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, AlarmReceiver::class.java)
            .putExtra("reservationId", reservationId)
            .putExtra("fireAt", fireAt)
            .putExtra("kind", kind)
        val pi = PendingIntent.getBroadcast(
            context, (kind + reservationId).hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            return
        }
        am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
    }

    /** 예고(-10분) 배너 */
    fun showPreAlert(context: Context, activityName: String, fireAt: Long) {
        val n = NotificationCompat.Builder(context, CHANNEL_REMINDER)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("'$activityName' 시작 10분 전입니다")
            .setContentText("촬영을 준비해주세요. 정각에 알람이 울립니다.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java)
            .notify(("pre$fireAt").hashCode(), n)
    }

    /** 마지막 경고(+5분) 배너 */
    fun showLastWarn(context: Context, activityName: String, fireAt: Long) {
        val n = NotificationCompat.Builder(context, CHANNEL_REMINDER)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("$activityName 시작")
            .setContentText("아직 시작하지 않았습니다. 5분이 지나면 탈락 처리됩니다.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java)
            .notify(("warn$fireAt").hashCode(), n)
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
        val am = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, AlarmReceiver::class.java)
        // 메인 + 예고 + 마지막 경고 전부 — 예약이 사라졌는데 보조 알람만 남으면
        // 라우팅 대상 없는 배너가 계속 온다
        for (code in listOf(reservationId.hashCode(),
                ("prealert" + reservationId).hashCode(),
                ("lastwarn" + reservationId).hashCode())) {
            val pi = PendingIntent.getBroadcast(
                context, code, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            am.cancel(pi)
        }
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
        stopAlarmVibration(context)
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

    private var vibrating = false
    private var vibrationAutoStop: Runnable? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** 알람이 울리는 동안 반복 진동 — 무음·방해금지 상태에서 소리가 어떤 이유로든
     *  안 들려도(볼륨 0, 이어폰 연결 등) 감각 채널이 하나 더 남는다.
     *  안드로이드는 iOS와 달리 백그라운드에서도 걸 수 있다. */
    @Suppress("DEPRECATION")
    fun startAlarmVibration(context: Context) {
        if (vibrating) return
        vibrating = true
        // 사용자가 알림을 무시하면 정지 경로(앱 진입)에 영영 도달하지 않는다 —
        // 시작 창(10분)이 끝나면 스스로 멈춘다. 창이 끝나면 노쇼라 더 울릴 이유도 없다.
        // 콜백 참조를 들고 있다가 정지 시 제거한다 — 안 지우면 알람 A가 걸어둔 자동
        // 정지가 뒤이어 시작된 알람 B의 진동을 조기에 끊는다.
        vibrationAutoStop?.let { mainHandler.removeCallbacks(it) }
        val autoStop = Runnable { stopAlarmVibration(context.applicationContext) }
        vibrationAutoStop = autoStop
        mainHandler.postDelayed(autoStop,
            com.singlemarks.angrymoti.models.TimePolicy.START_WINDOW_SECONDS * 1000)
        runCatching {
            val vib = if (Build.VERSION.SDK_INT >= 31) {
                context.getSystemService(android.os.VibratorManager::class.java).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(android.os.Vibrator::class.java)
            } ?: return
            val effect = android.os.VibrationEffect.createWaveform(
                longArrayOf(0, 800, 1200), 0)   // 0.8초 진동 + 1.2초 휴지 반복
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            vib.vibrate(effect, attrs)   // USAGE_ALARM — 방해금지에서도 울린다
        }
    }

    fun stopAlarmVibration(context: Context) {
        // 자동 정지 콜백은 항상 제거 — 이전 알람의 콜백이 다음 알람 진동을 끊지 않도록
        vibrationAutoStop?.let { mainHandler.removeCallbacks(it) }
        vibrationAutoStop = null
        if (!vibrating) return
        vibrating = false
        runCatching {
            val vib = if (Build.VERSION.SDK_INT >= 31) {
                context.getSystemService(android.os.VibratorManager::class.java).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(android.os.Vibrator::class.java)
            } ?: return
            vib.cancel()
        }
    }

    fun startAlarmSound(context: Context) {
        startAlarmVibration(context)   // 소리와 한 몸 — 무음이어도 이쪽은 남는다
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

    fun stopAlarmSound(context: Context? = null) {
        context?.let { stopAlarmVibration(it) }
        alarmPlayer?.run { runCatching { stop() }; release() }
        alarmPlayer = null
    }

    /** 세션 중 알림차단 (iOS muteAllNotifications) — 켜져 있으면 차임 무음 */
    @Volatile var sessionMuted = false

    // ── 시스템 방해 금지(DND) — 안드로이드는 권한만 받으면 앱이 직접 켜고 끌 수 있다
    /** 이번 세션에서 우리가 켠 것인지 (세션 종료 시 자동 해제용).
     *  DND는 시스템 전역 설정이라 프로세스가 죽어도 켜진 채 남는다 — 메모리 플래그만으로는
     *  크래시·강제 종료 후 원복할 방법이 없으므로 Prefs에도 함께 영속화한다. */
    @Volatile var dndEnabledByApp = false

    fun hasDndAccess(context: Context): Boolean =
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager)
            .isNotificationPolicyAccessGranted

    /** 방해 금지 켜기/끄기 — 권한 없으면 false.
     *  사용자가 이미 스스로 방해 금지를 켜둔 상태면 켜지도 끄지도 않는다 — 세션 종료가
     *  사용자의 수면 방해 금지까지 꺼버리면 안 된다. */
    fun setDnd(context: Context, on: Boolean): Boolean {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (!nm.isNotificationPolicyAccessGranted) return false
        if (on) {
            if (nm.currentInterruptionFilter !=
                android.app.NotificationManager.INTERRUPTION_FILTER_ALL) return true   // 사용자 DND 존중
            nm.setInterruptionFilter(android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY)
            dndEnabledByApp = true
            com.singlemarks.angrymoti.data.Prefs.dndEnabledByApp = true
        } else {
            nm.setInterruptionFilter(android.app.NotificationManager.INTERRUPTION_FILTER_ALL)
            dndEnabledByApp = false
            com.singlemarks.angrymoti.data.Prefs.dndEnabledByApp = false
        }
        return true
    }

    /** 세션이 켰던 방해 금지를 원복 — 세션 종료뿐 아니라 크래시 후 재실행(고아 복구)에서도
     *  불러야 한다. Prefs 플래그를 함께 봐서 프로세스가 죽었다 살아나도 원복된다. */
    fun restoreDndIfNeeded(context: Context) {
        if (dndEnabledByApp || com.singlemarks.angrymoti.data.Prefs.dndEnabledByApp) {
            setDnd(context, false)
        }
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
