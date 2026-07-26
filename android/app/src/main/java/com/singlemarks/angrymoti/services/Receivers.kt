package com.singlemarks.angrymoti.services

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.launch

/** 예약 시각 도달 — 풀스크린 알람 표시 후 다음 발생 재등록.
 *  재등록(DB 조회)은 goAsync로 프로세스를 붙잡아 끝까지 마친다 — onReceive가 반환하면
 *  OS가 프로세스를 죽여 재등록 코루틴이 유실될 수 있기 때문(반복 알람이 1회만 울리고 죽는 결함). */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val reservationId = intent.getStringExtra("reservationId") ?: return
        val fireAt = intent.getLongExtra("fireAt", System.currentTimeMillis())
        val kind = intent.getStringExtra("kind") ?: "alarm"
        val pending = goAsync()
        when (kind) {
            "prealert", "lastwarn" -> {
                // 유령 방어 + 시작 여부 확인은 DB를 봐야 한다 — goAsync로 프로세스 유지
                kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
                    try {
                        val db = com.singlemarks.angrymoti.data.AppDb.get(context.applicationContext)
                        val r = db.reservations().byId(reservationId)
                        if (r == null || !r.isActive) return@launch   // 삭제된 예약의 잔여 알람
                        if (kind == "lastwarn") {
                            // 이미 시작(완료·취소 포함)한 발생이면 경고를 보내지 않는다
                            val started = db.sessions().all(r.ownerUserID).any {
                                it.reservationID == reservationId &&
                                    it.scheduledAt != null &&
                                    kotlin.math.abs(it.scheduledAt!! - fireAt) < 60_000L
                            }
                            if (started) return@launch
                            AlarmScheduler.showLastWarn(context.applicationContext,
                                reservationId, r.name, fireAt)
                        } else {
                            AlarmScheduler.showPreAlert(context.applicationContext,
                                reservationId, r.name, fireAt)
                        }
                    } finally { pending.finish() }
                }
            }
            else -> {
                // 메인 알람도 예고/경고와 같은 유령 방어 — 삭제·비활성 예약의 잔여 알람이면
                // 풀스크린·진동 없이 재등록만 하고 조용히 지나간다.
                kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
                    try {
                        val db = com.singlemarks.angrymoti.data.AppDb.get(context.applicationContext)
                        val r = db.reservations().byId(reservationId)
                        if (r != null && r.isActive) {
                            AlarmScheduler.showAlarmNotification(context, reservationId, fireAt)
                            // 앱이 안 열려도 진동은 시작한다 — 풀스크린이 못 뜨는 상황(알림 거부 등)의 보루
                            AlarmScheduler.startAlarmVibration(context.applicationContext)
                        }
                    } finally {
                        AlarmScheduler.rescheduleAllAsync(context.applicationContext) { pending.finish() }
                    }
                }
            }
        }
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
