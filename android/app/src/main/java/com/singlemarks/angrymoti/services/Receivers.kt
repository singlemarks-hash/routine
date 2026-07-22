package com.singlemarks.angrymoti.services

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 예약 시각 도달 — 풀스크린 알람 표시 후 다음 발생 재등록.
 *  재등록(DB 조회)은 goAsync로 프로세스를 붙잡아 끝까지 마친다 — onReceive가 반환하면
 *  OS가 프로세스를 죽여 재등록 코루틴이 유실될 수 있기 때문(반복 알람이 1회만 울리고 죽는 결함). */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val reservationId = intent.getStringExtra("reservationId") ?: return
        val fireAt = intent.getLongExtra("fireAt", System.currentTimeMillis())
        AlarmScheduler.showAlarmNotification(context, reservationId, fireAt)
        val pending = goAsync()
        AlarmScheduler.rescheduleAllAsync(context.applicationContext) { pending.finish() }
    }
}

/** 재부팅 후 알람 전체 재등록 (AlarmManager는 재부팅 시 소멸).
 *  콜드 부팅은 DB 오픈이 느려 특히 유실 위험이 크므로 goAsync로 완료를 보장한다. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val pending = goAsync()
            AlarmScheduler.rescheduleAllAsync(context.applicationContext) { pending.finish() }
        }
    }
}
