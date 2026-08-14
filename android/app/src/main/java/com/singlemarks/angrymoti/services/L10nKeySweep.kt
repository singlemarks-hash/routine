package com.singlemarks.angrymoti.services

import android.content.Context
import android.util.Log
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.models.CanonicalTag
import com.singlemarks.angrymoti.models.ScoreNote

/**
 * 앱 시작 시 한 번, 로컬 Room의 태그·사유·note를 정본 키로 재작성한다
 * (docs/영어화-설계도.md D3 — iOS L10nKeySweep와 1:1).
 *
 * canonical(키) == 키 라서 몇 번을 돌아도 결과가 같다(멱등) — 플래그는 낭비 방지용일 뿐이다.
 * 클라우드 사본은 지우거나 고치지 않는다: 읽기 호환(레거시 역매핑)이 영구라 옛 문서는 그대로
 * 둬도 표시가 맞고, 다음 미러 때 자연히 키로 덮인다.
 */
object L10nKeySweep {

    suspend fun runIfNeeded(context: Context) {
        if (Prefs.l10nKeySweepDone()) return
        try {
            val db = AppDb.get(context)
            var changed = 0

            db.reservations().dumpAll().forEach { r ->
                val key = CanonicalTag.canonical(r.tag)
                if (key != r.tag) { db.reservations().upsert(r.copy(tag = key)); changed++ }
            }
            db.sessions().dumpAll().forEach { s ->
                val key = CanonicalTag.canonical(s.tag)
                val reason = s.emergencyReason?.let(ScoreNote::canonical)
                if (key != s.tag || reason != s.emergencyReason) {
                    db.sessions().upsert(s.copy(tag = key, emergencyReason = reason)); changed++
                }
            }
            db.scores().dumpAll().forEach { e ->
                val note = e.note?.let(ScoreNote::canonical)
                if (note != e.note) { db.scores().insert(e.copy(note = note)); changed++ }
            }

            Prefs.setL10nKeySweepDone()   // 전 구간 성공 시에만 — 실패하면 다음 실행에 재시도
            if (changed > 0) Log.i("AngryMoti", "L10n 키 스윕 완료 — ${changed}건 재작성")
        } catch (e: Exception) {
            Log.w("AngryMoti", "L10n 키 스윕 실패 — 다음 실행에 재시도: ${e.message}")
        }
    }
}
