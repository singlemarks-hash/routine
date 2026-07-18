package com.singlemarks.angrymoti.services

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 예약 시각 도달 — 풀스크린 알람 표시 후 다음 발생 재등록 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val reservationId = intent.getStringExtra("reservationId") ?: return
        val fireAt = intent.getLongExtra("fireAt", System.currentTimeMillis())
        AlarmScheduler.showAlarmNotification(context, reservationId, fireAt)
        AlarmScheduler.rescheduleAll(context)   // 반복 예약의 다음 발생 재등록
    }
}

/** 재부팅 후 알람 전체 재등록 (AlarmManager는 재부팅 시 소멸) */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            AlarmScheduler.rescheduleAll(context)
        }
    }
}
