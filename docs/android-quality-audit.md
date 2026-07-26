# 안드로이드 전수 품질 감사 — 최종 리포트 (디렉터 보고용)

- 감사 시점: 2026-07-26, 기준 커밋 `ff0288d` (WP0~WP8 이식 완료 + CI 그린 상태)
- 방법: 병렬 감사 4개 축(①데이터·정책·앱상태 ②그룹·계정·구독 ③세션·카메라·알람 ④UI 전체)으로
  안드로이드 전 파일을 iOS 정본과 라인 단위 대조. 수정 없이 보고만 수행.
- 심각도 기준:
  - **P0** — 데이터 파손·벌점 오부과·정책 우회가 확정적으로 발생 (즉시 수정)
  - **P1** — 사용자 피해가 크고 재현 조건이 흔함
  - **P2** — 조건부지만 실사용에서 발생
  - **P3** — 경미·이론적·iOS 정본과 공유하는 한계
- 총계: **P0 3건 / P1 16건(군집 기준) / P2 20건 / P3 다수**

> 핵심 소견: 크로스플랫폼 키·점수 도장·상태머신·노쇼 스위퍼 등 **핵심 파이프라인은 iOS와
> 정합함을 전수 확인**했다. 남은 결함의 대부분은 "iOS가 과거에 사고를 겪고 주석까지 남기며
> 고친 지점"이 안드로이드에 **수리 전 상태로 이식**된 형태다 (ScheduleConflict, 미친맛 강등,
> imminentOccurrences 하한, DatePicker UTC 등). CLAUDE.md의 "부분 이식 상태" 전제와 정확히 일치.

---

## 1부. P0 — 즉시 수정 (3건)

### P0-1. 유령 노쇼 부활 루프 — purgeNoShows가 세션 클라우드 사본을 안 지움
- 위치: `services/GroupStore.kt:766-778` (`removeLocalReservation`)
- 벌점(ScoreEvent)은 `deleteMirroredEvent`로 클라우드까지 회수하지만, **노쇼 세션 자체는 로컬만
  삭제**한다. iOS 정본(`GroupStore.swift:918`)은 `deleteMirroredSession`을 반드시 호출.
  노쇼 세션은 이미 `mirrorSession`으로 클라우드에 올라가 있으므로 다음 동기화가 그대로 되살린다.
  → CLAUDE.md 불변식 #4의 세션판 위반.
- **현상**: 인원 미달로 취소된 그룹방 노쇼를 정리했는데, 앱을 열 때마다 그 노쇼 세션이 부활해
  연속 달성일이 영구히 끊기고, "벌점 없는 세션만 있는 노쇼"가 기록에 계속 나타난다.
  매 동기화마다 삭제/부활 무한 반복.

### P0-2. 개인 예약 종료일(endDate)이 동기화에서 통째로 누락
- 위치: `services/AccountStore.kt:262-272` (`mirrorReservation` — endDate 키 자체가 없음),
  `:298-332` (`syncReservationsFromCloud` — 다운로드 시에도 읽지 않음)
- iOS는 업로드 시 nil도 NSNull로 키를 남기고(`AccountStore.swift:718-720`), 다운로드 시
  `keys.contains("endDate")` 검사로 병합(`:785`). 안드로이드 `endAt`은 개인 예약에서 실사용 중.
- **현상**: iOS에서 "7월 말까지"로 종료일을 건 예약이 안드로이드에는 **무기한**으로 내려와
  8월에도 알람이 계속 울리고 안 나가면 노쇼 벌점이 계속 쌓인다 — 불변식 #3
  "하루짜리가 영원히 울리던" 사고의 재판. 역방향(안드→클라우드)도 아예 안 올라간다.

### P0-3. 시작일 변경 시 종료일 '붙임' 클램프 → 요일 반복이 조용히 매일 알람으로 파괴
- 위치: `ui/ReservationEdit.kt:197` `endDayNorm = (oneOffEndDay ?: startDay).coerceAtLeast(startDay)`
  (표시 경로 `:391`도 동일)
- iOS(`ReservationEditView.swift:404-420`)는 이 방식을 명시적으로 금지하고 **기간 길이를 보존해
  통째로 민다**. 클램프 탓에 `:205`의 `endDayNorm < startDay` 검증은 영원히 도달 불가(죽은 코드).
- **현상**: 월·수·금 반복(종료일 있음) 예약의 시작일을 종료일 뒤로 옮기면 시작일=종료일이 되어
  요일 UI가 사라지고, 저장 시 `repeatWeekdaysCsv="1,…,7"`(매일)로 덮인다 →
  **매일 알람이 울리고 안 나간 날마다 노쇼 벌점**.

---

## 2부. P1 — 높은 우선순위 (군집별)

### A군. 겹침 검사(ScheduleConflict) 부재 — 3개 호출부 공통 (감사 3축에서 독립 검출)
- 위치: `ui/ReservationEdit.kt:181-186` (개인 편집), `services/GroupStore.kt:361-390`
  (그룹 생성/참여 `checkScheduleConflict`)
- iOS 정본 `ScheduleConflict.conflicts`(`Models.swift:315-380`)는 겹치는 기간의 실제 날짜를
  8일 스캔해 (a) 활성 기간, (b) 요일별 점유 구간, (c) 자정 넘김 꼬리(`end > 1440`)까지 판정.
  안드로이드는 이 셋이 전부 없고, 개인 편집 쪽은 **요일 교집합 검사조차 없다**.
  iOS가 `Models.swift:312-314` 주석으로 "그래서 고쳤다"고 기록한 바로 그 결함.
- **현상**:
  - 오탐: 월요일 09:00 예약이 있으면 화요일 09:00 새 예약이 영영 차단.
  - 오탐: 6월에 끝난 활동이 8월 같은 시각 활동/그룹 참여를 계속 차단 — 지울 예약이 화면에 안 보임.
  - 오탐: 매일/하루 모드가 전체 요일 CSV로 저장되어 날짜가 달라도 무조건 충돌 판정.
  - 미탐: 토 23:00 시작 8시간 활동 vs 일 02:00 활동이 통과 → 알람 2개 동시 발화, 한쪽 노쇼.

### B군. 알람 라우팅이 진행 중 세션을 강탈 + 유령/스테일 인텐트 방어 부재 (감사 2축 독립 검출)
- 위치: `MainActivity.kt:67-77` (`handleIntent`) — `route = Route.Alarm` **무조건 대입** + 알람음 시작.
- iOS `checkDueAlarm`(`TimeLockApp.swift:419`)의 `guard route == .none, session == nil` 가드와
  `isGhostAlarm`(삭제된 예약 방어, `:441`) 상당이 모두 없다. `fireAt` 신선도 검사도 없어
  recents에서 재실행하면 며칠 전 알람 인텐트가 재처리된다.
- **현상**: ① 촬영 중 다른 알람이 오면 촬영 화면이 알람 화면으로 교체되고 세션으로 돌아갈
  동선이 없다 — 당황해 조작하다 이탈 판정 위험. ② 한밤중 최근 앱에서 열었는데 어제 아침
  알람 화면이 뜨고 알람음이 울린다. ③ 로그인/온보딩 전 알람 인텐트는 소리만 시작되고
  화면이 없어 끌 수 없다(P2-연계).

### C군. +5분 '마지막 경고'가 발화 순간 소멸 — 3단 에스컬레이션의 마지막 단이 항상 죽어 있음
- 위치: `services/AlarmScheduler.kt:70-104`, `services/Receivers.kt:44`
- 보조 알람 PendingIntent 슬롯이 예약당 1개인데, 정각 발화 직후 리시버의 rescheduleAll이
  `nextOccurrence()`(이미 **내일**)로 같은 requestCode를 재등록해 **방금 울린 발생의
  +5분 경고를 덮어 지운다**. iOS는 `imminentOccurrences` 하한을 `now - 시작창`으로 잡아
  이 함정을 명시적으로 막는다(`AlarmScheduler.swift:253-271`) — 이 로직이 이식 누락.
- **현상**: 알람을 못 들으면 "5분이 지나면 탈락 처리됩니다" 경고가 영영 안 오고 그대로 노쇼.
  매 알람마다 무조건 재현.

### D군. 촬영 중 크래시 시 시스템 방해금지(DND)가 켜진 채 영구 잔류
- 위치: `services/SessionEngine.kt:74, 436-446, 661-692`, `services/AlarmScheduler.kt:303`
- DND는 시스템 전역 설정인데 원복 플래그가 메모리 전용이고, 고아 세션 복구
  (`recoverOrphanIfNeeded`)가 DND 원복을 부르지 않는다. 안드로이드 고유 기능이라 iOS 정본에
  대응 코드가 없음 — 고유의 뒷정리 불변식이 필요.
- **현상**: 촬영 중 배터리 방전 후 전화·카톡이 전부 무음. 사용자는 앱과 연관 짓지 못하고
  "폰 고장"으로 인식. (연계 P2: 원복이 '이전 상태 복원'이 아니라 무조건 해제라, 사용자가
  스스로 켜둔 수면 DND까지 꺼버림 — `AlarmScheduler.kt:310-319`)

### E군. 클라우드 병합 규칙 3종 누락 (예약 필드)
- 위치: `services/AccountStore.kt:296-313`
  1. `accountableFrom` — max 병합 없이 클라우드 값 그대로 수용 → 면책 기준이 과거로 되돌아가
     이미 면책된 오늘 아침 발생분이 소급 노쇼 (불변식 #2 위반).
  2. `repeatWeekdays` — 빈 배열 방어 없음 → 구버전 문서 하나로 매일 반복이 하루짜리로 붕괴,
     내일부터 알람이 안 울림 (iOS는 `!isEmpty` 가드).
  3. `createdAt` — 병합 로직 자체가 없음 → iOS에서 시작 전 예약의 시작일을 미뤄도 안드로이드가
     옛 시작일을 유지, 미룬 기간 전체가 노쇼 집계 (iOS는 "시작 전 원격 수용 / 시작 후 min 유지").

### F군. 그룹 서버 실패 처리 2건
1. **join()의 groupIDs arrayUnion 실패 삼킴** — `GroupStore.kt:437-441`. iOS는 명시적으로 던짐
   (`GroupStore.swift:515-523` 주석: 삼키면 고아 정리가 방금 만든 예약을 지움). 현상: 참여 직후
   네트워크가 흔들리면 서버엔 멤버인데 예약·알람이 prune으로 삭제 → **알람은 안 울리는데
   그룹 노쇼 벌점만 매일 쌓임**.
2. **onCreate/onStart 이중 동기화 파이프라인 경합** — `MainActivity.kt:42-56, 97-105`.
   Mutex/인플라이트 가드 없이 콜드 스타트에서 동시 실행 → 게이트가 중간에 열려 세션 미병합
   상태로 노쇼 스윕 진입 가능. 현상: 아이폰에서 완주한 날 안드로이드를 켜면 간헐적으로 -15가
   찍혔다 사라지는 유령 벌점. (부수: `rescheduleAll` 이중 호출)

### G군. 계정 삭제 2건
- 위치: `services/AccountStore.kt:149-159`
  1. **sessionSummaries 미삭제** — 계정 삭제 후에도 활동명·시각·성패 이력 전체가 Firestore에
     영구 잔존. 개인정보 이슈 + 스토어 심사 리스크. (iOS `AccountStore.swift:448-450`)
  2. **Auth 삭제 실패(requiresRecentLogin) 삼킴** — 데이터만 지워지고 계정은 살아있는데 화면은
     "삭제 완료". 재가입 시 "이미 가입된 이메일" 오류.

### H군. 예약 편집 화면 결함 3건 (P0-3과 같은 파일)
- 위치: `ui/ReservationEdit.kt`
  1. **미친맛 예약이 열기만 해도 매운맛으로 강등** (`:124`) — iOS가 과거 사고 후
     `isLockedInsane` 읽기 전용 모드로 고친 결함(`ReservationEditView.swift:511-514`)의 재현.
     현상: 멤버십 만료 후 이름만 고쳐도 벌점 기준이 조용히 절반이 됨.
  2. **시작일 잠금 판정 오류** (`:155-157`) — `createdAt+startMinute` 경과로만 판정. iOS는 실제
     첫 발생을 8일 스캔. 현상: 월요일에 만든 '토요일마다' 예약이 첫 발생 전인데 월요일 저녁부터
     잠기고, 레거시 일회성 예약은 잠김 오판 + 저장 시 '생성일부터 매일'로 손상.
  3. **검증 A/B 부재** — "기간 안에 고른 요일이 오는가" + "미래 발생이 남았는가" 검증이 없어
     태어날 때부터 죽은 예약(알람 0회)이 오류 없이 저장됨.

### I군. 촬영/알람 화면 결함 2건
- 위치: `ui/CaptureFlow.kt`
  1. **결과 화면 '종료'가 썸네일까지 삭제 + DB 파일명 미정리** (`:1055`) — iOS는 영상만 지우고
     썸네일 보존 + `videoFileName=nil` 정리. 현상: 캘린더 '이 날의 기록' 썸네일 전멸,
     화면 문구 "기록은 유지됩니다"와 모순.
  2. **알람 취소 벌점 안내가 전역 강도 기준 + 폴백 -5** (`:133`) — iOS는 활동별 강도 + 폴백 -10
     (`AlarmView.swift:122-126` 주석에 이유 명시). 현상: 미친맛 활동 취소 시 -5로 안내하고
     실제로는 2배 벌점 부과 — 안내와 실부과 불일치.

### J군. 그룹 화면 결함 3건
- 위치: `ui/GroupScreens.kt`
  1. **진행 중 방 상세에 '활동 시작하기' 카드 부재** (`:1004-1071`) — 알람을 놓친 참여자가 방에
     들어와도 시작할 방법이 없어 그대로 노쇼. (iOS `GroupStartActivityCard`)
  2. **cancelled/disbanded 방이 else 분기로 흘러 '중도 포기(-50)' 버튼 노출** (`:860-863, 1064-1069`)
     — 이미 취소된 방에서 스스로 -50을 무는 경로. iOS는 '방 나가기'만 노출.
  3. **방 만들기 DatePicker — UTC 환산 절반 누락 + selectableDates 없음** (`:677-678`) —
     KST에서 하루 전 날짜로 표시. CLAUDE.md가 기록한 'DatePicker UTC 환산 누락' 결함이
     이 화면에 잔존 (개인 예약 편집 쪽은 올바름).

---

## 3부. P2 — 조건부 발생 (요약)

| # | 결함 | 위치 | 현상 요약 |
|---|---|---|---|
| 1 | muxer.stop() 실패 삼킴 → 손상 영상이 '완주 만점' | `TimelapseEncoder.kt:192-198` | 4시간 완주 점수는 받았는데 영상이 재생 불가 — 헛완주 방어가 이 지점만 뚫림 |
| 2 | sync 조용한 실패 시 initialSync 게이트가 그냥 열림 | `MainActivity.kt:48-55`, `AccountStore.kt` | 오프라인에서 앱을 열면 타기기 완주가 병합되기 전에 노쇼 스윕 → 벌점 생겼다 사라짐 |
| 3 | 진동 정지 경로 2건 (postDelayed 유실·크로스톡) | `AlarmScheduler.kt:234-266` | 무음폰에서 진동이 조기 종료 → 노쇼; A알람 정지 콜백이 B진동을 5분 일찍 끔 |
| 4 | endAt 판정식 iOS 불일치 (`fire > endAt` vs 날짜 기준) | `Entities.kt:65` | 자정값 endDate 유입 시 마지막 날 알람이 iOS만 울림 — 크로스기기 벌점 불일치 |
| 5 | defaultStartMinute가 날짜를 버림 (23시+) | `Models.kt:21-25` | 밤 11시 예약 화면 기본값이 '이미 지난 오늘 01:00' |
| 6 | pendingDowngrade 비반응형 + 30초 상시 적용 부재 | `AppState.kt:66-95` | 하향 눌러도 화면 무반응; 자정 넘겨 포그라운드 유지 시 미친맛 2배 벌점 유지 |
| 7 | byId/bySession 소유자 필터 없음 | `Db.kt:22-23, 49-50, 73-74` | 공유 태블릿에서 형의 알람을 동생 계정이 받아 '일정 취소' 시 동생에게 -10 |
| 8 | 30초 sweep 타이머 부재 (iOS 안전망 공백) | `MainActivity.kt` | OEM이 알람을 죽이면 앱을 켜두고 있어도 알람 화면이 안 뜸 |
| 9 | 일정 탭 시계 틱 없음 | `ReservationEdit.kt:755` | 탭을 열어둔 채 시간이 지나도 흐림/오늘 배지가 안 바뀜 |
| 10 | MountGuide 재생성 시 화면 고착 | `CaptureFlow.kt:168` | 카운트다운 중 다크모드 전환 → 녹화는 도는데 가이드 화면에 영영 멈춤 |
| 11 | 캡처 플로우 전체 BackHandler 부재 | `CaptureFlow.kt` 전반 | 뒤로가기로 알람/세션/결과 화면 이탈 — 저장 파이프라인 건너뜀 |
| 12 | 일정취소 시트가 알람음 정지/재개를 안 함 | `CaptureFlow.kt:139-156` | 시트가 떠도 알람이 계속 울림 (iOS는 즉시 멈추고 '돌아가기'면 재개) |
| 13 | 긴급중단 예산 수집만 하고 미사용 | `CaptureFlow.kt:538` | 예산 소진돼도 버튼이 계속 눌림 — UI가 거짓말 |
| 14 | 방 상세 자동 갱신 없음 | `GroupScreens.kt:852-858` | '확인 중' 카드가 영원히 안 풀림, 랭킹이 진입 시점 스냅샷 고정 |
| 15 | doomed 카드 중복 + 액션 전무 | `GroupScreens.kt:901-935` | 폭파 경고 2장 중복, 시작 전인데 해체/탈퇴 버튼이 없음 |
| 16 | 로그아웃 확인 다이얼로그 없음 | `SettingsScreens.kt:209-211` | 오터치 즉시 로그아웃 |
| 17 | 계정 삭제 로컬-우선 + 오류 처리 없음 | `SettingsScreens.kt:283-296` | 서버 삭제 실패해도 로컬만 소실, 표시 없음 |
| 18 | 세션 복원 시 미인증 이메일 홀드 누락 | `AccountStore.kt:44-48` | 인증 대기 화면 대신 로그인 화면으로 떨어짐 |
| 19 | refresh() isRefreshing 비원자 + quitAfterStart의 removeMembershipRef 무시 | `GroupStore.kt:123-124, 670` | 해체 안내 카드 2장 중복; 포기한 방이 목록에 유령으로 잔존 |
| 20 | 완주율 분모 불일치 (`successes/finished` vs iOS `completions/started`) | `CalendarScreen.kt:166` | 노쇼가 많을수록 안드로이드 완주율이 더 낮게 표시 |
| 21 | versionCode 수동 관리 | `build.gradle.kts:30-31` | 릴리스 시 올리는 걸 잊으면 Play 업로드 거부 |

## 4부. P3 — 경미 (대표만, 상세는 감사 원문)

죽은 코드(spicyCompletions, IntensityScreen, 앱 언어 메뉴), Room 인덱스 전무, requestCode 해시
충돌 여지, delivered 배너 미정리, DST 고정 86,400,000ms 산술(국내 무해), GoogleSignIn nonce 부재,
게스트 프로필 분기 없음, 썸네일 전체 삭제 기능 미이식, 태그별 시간 분포 카드 미이식,
메인스레드 비트맵 디코드, rememberSaveable 필요 지점 4곳, 하드코딩 리터럴 다수,
datastore 미사용 의존성, exportSchema=false 등.

## 5부. 이상 없음 확인 (전수 대조 완료 항목)

- **크로스플랫폼 키**: 그룹 도장 키(대문자 UUID+초)·노쇼 이벤트 ID(소문자 hex)·markID·
  stableReservationId — 바이트 단위 일치. Timestamp/millis 필드 유형 전수 대조 일치.
- **점수 트랜잭션**: applyScore/revokeScore/repairMyScore rank 비교·차액 보정·CAS — iOS와 동치.
- **세션 상태머신**: 모든 종료 경로의 isFinalizing 선점, 브레이크 예산, 자리비움 30/120/3회,
  에피소드 리셋 — 1:1 일치.
- **노쇼 스위퍼**: grace 경계식, 개인 2일/그룹 92일 소급, accountabilityStart 게이트,
  생성 전 노쇼 복구(클라우드 포함) — 동등.
- **GroupStore.refresh() 분기 순서**: 문서소실→해체→doomed 승계→판정→시작 CAS→취소→만료→ensure
  전부 iOS와 1:1. 실패 시 이전 상태 보존·판정 유예 방어 동일.
- **동기화 6종 병합** 중 scoreEvents/sessionSummaries/bonusState/membership/homeGoal — 이상 없음
  (reservations만 P0-2/E군).
- 게스트 격리, 미러 owner 스코프, 캡처 간격 보간, 부재 감지, BootReceiver, manifest 권한 구성.

---

## 6부. 개선 작업 플래닝 (제안 — 작업지시 대기)

원칙: **벌점·알람의 신뢰(제품의 핵심 약속)를 깨는 것부터.** 각 단계는 커밋+CI 검증 단위.

### QF1. 크로스플랫폼 데이터 정합 (P0-1, P0-2, E군, F-1) — 최우선
서버를 오가는 데이터가 왜곡되는 결함들. 시간이 지날수록 오염 데이터가 쌓여 나중에 고쳐도
과거분을 복구하기 어려워지므로 가장 먼저.
1. `removeLocalReservation`에 `deleteMirroredSession` 추가 (P0-1)
2. `mirrorReservation`/`syncReservationsFromCloud`에 endDate 왕복 추가 (P0-2)
3. 병합 규칙 3종: accountableFrom max / repeatWeekdays 빈 배열 가드 / createdAt 병합 (E군)
4. join() arrayUnion 실패를 던지도록 (F-1)

### QF2. 예약 편집·검증 (P0-3, H군, A군-개인, P2-5)
ReservationEdit.kt 한 파일에 집중된 군집 — 한 번에 수리.
1. 시작일 이동 시 기간 길이 보존 (P0-3)
2. ScheduleConflict 상당 구현 (Models.kt에 iOS `conflicts` 이식 — 기간·요일·자정 꼬리)
   후 개인 편집·그룹 양쪽 호출부 교체 (A군)
3. isLockedInsane 읽기 전용 모드 (H-1) / 첫 발생 8일 스캔 잠금 판정 (H-2) / 검증 A/B (H-3)
4. defaultStartMinute 날짜 보존 (P2-5)

### QF3. 알람 신뢰성 (C군, B군, D군, P2-3, P2-8, P2-12)
1. rescheduleAll에 `now - 시작창` 하한의 imminent 발생 복구 (C군 — iOS 패턴 그대로 이식)
2. handleIntent 가드 3종: 세션 중 라우팅 금지 / 유령 알람 / fireAt 신선도 (B군)
3. DND: 플래그 영속화(Prefs) + 고아 복구 시 원복 + 이전 필터 저장·복원 (D군, P2-DND)
4. 진동 정지 콜백 취소 + 정지 시각 AlarmManager 예약 (P2-3)
5. 취소 시트 알람음 정지/재개 (P2-12), 30초 sweep 틱 (P2-8)

### QF4. 그룹·계정 수명주기 (J군, G군, F-2, P2-14~19)
1. GroupStartActivityCard 이식 (J-1) / cancelled·disbanded 분기 (J-2) / DatePicker UTC+범위 (J-3)
2. deleteAccount: sessionSummaries 삭제 + requiresRecentLogin 표면화 + 서버-우선 순서 (G군, P2-17)
3. onCreate/onStart 파이프라인 Mutex 단일화 (F-2) + isRefreshing CAS (P2-19)
4. 방 상세 자동 갱신 + doomed 분기 정리 (P2-14, 15), 미인증 세션 홀드 (P2-18)

### QF5. 세션·UI 마감 (I군, P2 잔여, P3 선별)
1. 썸네일 보존 + videoFileName 정리 (I-1) / 취소 벌점 활동별 강도 (I-2)
2. muxer.stop 실패 시 실패 반환 (P2-1), sync 실패 시 게이트 미개방 (P2-2)
3. BackHandler·MountGuide rememberSaveable·시계 틱·완주율 분모·로그아웃 확인 등
4. P3 선별: 죽은 코드 제거, byId owner 필터, versionCode CI 주입

### 규모 감각
- QF1: 소규모(파일 2개, 반나절 급) — 효과 대비 비용 최소
- QF2: 중규모(ScheduleConflict 신규 구현 포함)
- QF3: 중규모(안드로이드 고유 로직 다수)
- QF4·QF5: 중소규모 다건 병렬 가능

> 참고: DST/타임존 계열(P2-4, P3 다수)은 국내 사용자에게 무해하므로 D8(월클록 키, 1.1)과 함께
> 별도 트랙으로 미룸을 제안. Play Billing 실기기 검증(D6 obfuscatedAccountId 포함)은
> Play Console 상품 등록 후 디바이스 체크리스트(포트 플랜 §5)와 함께 진행.
