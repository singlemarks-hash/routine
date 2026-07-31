package com.singlemarks.angrymoti.services

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.singlemarks.angrymoti.data.Prefs

/**
 * 런타임 권한 판정·요청·설정 유도를 한곳에 모은다.
 *
 * 온보딩에서만 권한을 물어보던 시절, 거기서 건너뛴 사용자는 앱 어디서도 다시 요청받지
 * 못했다(알림 없이 알람이 조용히 사라지고, 촬영은 토스트만 뜨고 끝났다). iOS에서 같은
 * 결함을 '기능을 쓰는 순간 지연 요청'으로 고쳤고, 여기가 그 안드로이드 대응이다.
 *
 * 안드로이드 고유 함정 — **두 번 거부하면 그 뒤 launch()는 시스템 창 없이 즉시 denied**다.
 * 이 상태(iOS의 blocked)를 구분하지 못하면 사용자는 아무 반응 없는 버튼만 누르게 된다.
 * 구분 방법은 shouldShowRequestPermissionRationale 하나뿐인데, 이 값은 '한 번도 안 물어본
 * 상태'에서도 false라 그것만으로는 '아직 안 물어봄'과 '영구 거부'가 같아 보인다.
 * 그래서 물어본 사실을 Prefs에 남겨 두 상태를 갈라낸다.
 */
object Permissions {

    const val CAMERA = android.Manifest.permission.CAMERA
    const val NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"

    /** 요청 결과 — iOS AlarmScheduler.PromptOutcome와 같은 3분기 */
    enum class Outcome {
        /** 원래 허용이었거나 방금 허용함 */
        AUTHORIZED,

        /** 방금 시스템 창에서 거부 — 또 안내하면 잔소리가 된다 */
        JUST_DECLINED,

        /** 이미 거부(또는 정책 제한) — 시스템 창이 다시 뜨지 않으므로 설정으로 보내야 한다 */
        BLOCKED,
    }

    // MARK: - 판정

    fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    fun cameraGranted(context: Context): Boolean = granted(context, CAMERA)

    /**
     * 알림을 실제로 띄울 수 있는가.
     *
     * POST_NOTIFICATIONS 권한만 보면 안 된다 — API 32 이하에는 그 권한 자체가 없고,
     * 허용한 뒤 설정에서 알림을 꺼버린 경우도 권한은 granted로 남는다.
     * 실제 표시 가능 여부는 areNotificationsEnabled()가 모든 버전에서 정답이다.
     */
    fun notificationsEnabled(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    /**
     * 시스템 창이 더는 뜨지 않는 상태인가.
     *
     * '아직 안 물어봄'과 '영구 거부'는 shouldShowRequestPermissionRationale만으로는
     * 둘 다 false라 구분되지 않는다 — 물어본 기록(Prefs)을 함께 본다.
     */
    fun isBlocked(activity: Activity, permission: String): Boolean {
        if (granted(activity, permission)) return false
        if (!Prefs.permissionAsked(permission)) return false   // 첫 요청 — 창이 뜬다
        return !ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)
    }

    /** 알림이 꺼져 있고, 시스템 창으로는 되돌릴 수 없는 상태 (설정으로 보내야 함) */
    fun notificationsBlocked(activity: Activity): Boolean {
        if (notificationsEnabled(activity)) return false
        // API 32 이하는 런타임 권한이 없다 — 꺼져 있다면 사용자가 설정에서 끈 것이므로
        // 되돌릴 방법도 설정뿐이다.
        if (Build.VERSION.SDK_INT < 33) return true
        return isBlocked(activity, NOTIFICATIONS)
    }

    /** 요청을 실제로 보냈다고 기록 — isBlocked 판정의 기준점 */
    fun markAsked(permission: String) = Prefs.markPermissionAsked(permission)

    // MARK: - 알람 신뢰성 (안드로이드 고유)

    /**
     * 전체 화면 알람을 띄울 수 있는가.
     *
     * API 34부터 USE_FULL_SCREEN_INTENT는 통화·알람 카테고리 앱에만 자동 부여된다.
     * 거부돼 있으면 setFullScreenIntent가 조용히 일반 배너로 격하돼, 잠금 화면에서
     * 알람 화면이 뜨지 않는다 — 알람 앱에는 치명적이라 별도로 점검·안내한다.
     */
    fun canUseFullScreenAlarm(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        return runCatching {
            context.getSystemService(android.app.NotificationManager::class.java)
                .canUseFullScreenIntent()
        }.getOrDefault(true)
    }

    /**
     * 배터리 최적화 예외인가.
     *
     * setAlarmClock은 Doze 면제라 순정에서는 문제없지만, 삼성 '미사용 앱 절전' 같은 OEM
     * 정책에 걸리면 알람 자체가 오지 않는다. 갤럭시에서 실제로 겪는 유형이라 점검 대상이다.
     */
    fun isBatteryUnrestricted(context: Context): Boolean = runCatching {
        context.getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(context.packageName)
    }.getOrDefault(true)

    // MARK: - 설정 화면 유도

    private fun launch(context: Context, intent: Intent) {
        // OEM에 따라 없는 화면이 있다 — 실패해도 앱이 죽으면 안 되므로 앱 상세로 폴백한다.
        runCatching {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure {
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri(context))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        }
    }

    private fun pkgUri(context: Context): Uri = Uri.parse("package:${context.packageName}")

    /** 앱 상세 설정 (권한 화면 진입점) */
    fun openAppSettings(context: Context) =
        launch(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri(context)))

    /** 이 앱의 알림 설정 — 채널별 스위치가 바로 보인다 */
    fun openNotificationSettings(context: Context) = launch(
        context,
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    )

    /** 전체 화면 알람 허용 화면 (API 34+) */
    fun openFullScreenAlarmSettings(context: Context) {
        if (Build.VERSION.SDK_INT < 34) return openAppSettings(context)
        launch(context, Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, pkgUri(context)))
    }

    /**
     * 배터리 최적화 예외 요청.
     *
     * 직접 요청(ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)은 Play 정책상 허용 사유가
     * 명확한 앱만 쓸 수 있다 — 정시 알람이 본질 기능인 알람 앱은 해당된다.
     */
    fun requestBatteryUnrestricted(context: Context) = launch(
        context,
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkgUri(context))
    )
}
