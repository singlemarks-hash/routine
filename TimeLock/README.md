# 타임락 (TIMELOCK)

**알람을 끄는 유일한 방법, 촬영 시작.**

예약한 활동 시각에 강제 알람이 울리고, 알람을 끄려면 전면 카메라 타임랩스 촬영을 시작해야 합니다.
촬영이 곧 잠금이 되어 폰 점유와 자기감시를 만들고, 완주하면 상점과 성공캘린더 기록이 쌓입니다.
**10분** 안에 시작하지 않으면 노쇼 탈락 — 벌점입니다.

상점·벌점·기록은 **계정 단위**로 관리됩니다 (이메일 회원가입 · Google · Apple · 게스트).
촬영본은 세션 종료 화면에서 사진 앱으로 저장하지 않으면 **자동 삭제**됩니다.

## 요구 사항

- Xcode 16 이상
- iOS 17.0+ (실기기 권장 — 카메라·알림·통화 감지는 시뮬레이터에서 제한적)
- Swift 5.10+, SwiftUI + SwiftData

## 빌드 & 실행

1. `TimeLock.xcodeproj`를 Xcode로 엽니다.
2. **Signing & Capabilities**에서 팀을 선택하고 번들 ID(`com.timelock.app`)를 필요 시 변경합니다.
3. 실기기를 선택하고 Run.

프로젝트는 **폴더 동기화 그룹**(objectVersion 77)을 사용하므로, `TimeLock/` 아래에 파일을
추가하면 pbxproj 수정 없이 자동으로 타깃에 포함됩니다.

## 계정 & 백엔드 연동 (Firebase)

앱은 **Firebase(Auth + Firestore)** 를 백엔드로 사용하도록 준비되어 있습니다.
모든 Firebase 코드는 `#if canImport(...)` 뒤에 격리되어 있어 **패키지를 추가하지 않아도 빌드·실행됩니다**
(이 경우 '기기 내 계정' 오프라인 폴백으로 동작 — 개발/시뮬레이터 테스트용).

현재 연동 상태:

- [x] `GoogleService-Info.plist` 추가됨 (프로젝트 `timelock-eba85`)
- [x] SPM 패키지 추가됨 — firebase-ios-sdk(FirebaseAuth, FirebaseFirestore), GoogleSignIn-iOS
- [x] Google 로그인 제공업체 활성화 + `CLIENT_ID` 포함 plist로 교체
- [x] `REVERSED_CLIENT_ID` URL Scheme 등록 (Info.plist) + 콜백 처리(`onOpenURL`)
- [ ] Firebase 콘솔 > Authentication에서 **이메일/비밀번호, Apple** 제공업체 활성화
- [ ] Signing & Capabilities에 **Sign in with Apple** capability 추가
      (App Store 심사 규정 4.8 — Google 등 서드파티 로그인을 제공하면 Apple 로그인 제공이 **필수**)
- [ ] Firestore 보안 규칙 배포 (본인 문서만 접근 — 콘솔 > Firestore > 규칙)

패키지가 링크되고 plist가 존재하면 `AccountStore`가 자동으로 Firebase 모드로 전환됩니다.
점수 원장(상점·벌점)은 로컬 SwiftData가 원본이고, 로그인 계정은 `users/{uid}/scoreEvents`로
Firestore에 백업됩니다. 영상은 어떤 경우에도 서버로 전송되지 않습니다.

게스트로 쌓은 기록은 첫 로그인 시 해당 계정으로 자동 귀속됩니다.

### StoreKit 테스트 (구독)

Scheme > Edit Scheme > Run > Options > **StoreKit Configuration**에서
`TimeLock.storekit`을 선택하면 시뮬레이터/기기에서 `com.timelock.pro.monthly`
구독(워터마크 제거)을 실결제 없이 테스트할 수 있습니다.

## 알람 구현에 대하여

| 환경 | 동작 |
|---|---|
| 기본 (iOS 17+) | Time-Sensitive 로컬 알림 + 2분 간격 재알림 4회 (10분 창). 앱이 실행 중이면 즉시 풀스크린 알람 화면 + 오디오 루프 재생 |
| iOS 26+ (선택) | AlarmKit 기반 시스템 풀스크린 알람 (무음 모드 관통) |

### AlarmKit 활성화 방법 (iOS 26 SDK 사용 시)

빌드 보장을 위해 AlarmKit 코드는 컴파일 플래그 뒤에 격리되어 있습니다.

1. Build Settings > **Swift Compiler – Custom Flags** > Active Compilation Conditions에 `ENABLE_ALARMKIT` 추가
2. Signing & Capabilities에서 **AlarmKit** capability 추가 (Info.plist의 `NSAlarmKitUsageDescription` 포함)
3. `Services/AlarmScheduler.swift`의 `#if ENABLE_ALARMKIT` 블록이 활성화됩니다 — 어댑터 지점에 AlarmKit 스케줄링 코드를 연결하세요.

### Time-Sensitive 알림

무음/집중 모드를 일부 관통하려면 **Time Sensitive Notifications** entitlement가 필요합니다.
Signing & Capabilities > + Capability > Time Sensitive Notifications를 추가하세요.
(App Store Connect에서 해당 entitlement 사용 사유를 요구할 수 있습니다 — "사용자가 직접 예약한
활동 시작 알람"이라고 기재하면 됩니다.)

## 아키텍처 개요

```
TimeLock/
├── TimeLockApp.swift        앱 진입점, AppState(라우팅/강도/노쇼 스위프), 알림 딜리게이트
├── Theme/Theme.swift        디자인 시스템 — REC 링 모티프, 팔레트, 타이포, 컴포넌트
├── Models/Models.swift      TimePolicy / Reservation / FocusSession / ScoreEvent(원장) / ScoreRules
├── Services/
│   ├── AccountStore.swift   계정(이메일/Google/Apple/게스트), Firebase 게이팅, 점수 클라우드 백업
│   ├── AlarmScheduler.swift 로컬 알림 스케줄링, 알람 오디오, 재촬영 창 알림, AlarmKit 어댑터 지점
│   ├── CameraRecorder.swift 전면 카메라 1fps 캡처 → HEVC 타임랩스 (1시간 = 2분 영상)
│   ├── SessionEngine.swift  세션 상태머신 — 긴급 중단/재촬영 창, 통화 일시정지, 안전 종료, 노쇼
│   └── ExportAndSubscription.swift 워터마크 + 사진 앱 저장(VideoDownloader) + StoreKit 2 구독
└── Views/                   온보딩 / 출석부(Auth) / 홈 / 예약 / 알람 / 세션 / 캘린더·통계 / 설정·페이월
```

### 핵심 규칙 구현 지점

| 규칙 | 위치 |
|---|---|
| 알람 해제 = 촬영 시작에서만 | `AppState.beginRecording`에서만 `stopAlarmSound()` 호출 |
| 10분 미시작 = 노쇼 탈락 | `TimePolicy.startWindowSeconds`, `SessionEngine.sweepNoShows` (30초 주기) |
| 긴급 용무 중단 → 10분 재촬영 창 (매운맛) | `SessionEngine.startBreak/resumeFromBreak`, 이탈도 동일 취급 |
| 재촬영 창 초과·계속 이탈 = 벌점 | `failBreakExpired` + 결과 화면의 누적 벌점 표시 |
| 미친 매운맛 즉시 실패·벌점 2배 | `handleExitEvent` insane 분기, `ScoreRules` |
| 통화 = 무벌점 일시정지·종료 연장 | `CXCallObserver` → pause/resume, 완주는 '순수 촬영 초' 기준 |
| 킬/크래시 복구 | `recoverOrphanIfNeeded` (breakDeadline 유무로 이탈/안전 종료 판별) |
| 촬영본 저장 안 하면 자동 삭제 | `SessionResultView`(저장) + `AppState.dismissResult/purgeUnsavedVideos`(삭제) |
| 회원별 상점·벌점 | 모든 모델의 `ownerUserID`, `AccountStore`(게스트 기록 자동 귀속, Firestore 백업) |
| 강도 상향 즉시·하향 익일 0시 | `AppState.requestIntensityChange` |
| 미친 매운맛 해금 (매운맛 완주 3회) | `AppState.insaneUnlocked` |
| 규칙 변경 시 재계산 | `ScoreEvent` 원장이 원본 이벤트 보존, `ScoreRules` 순수 함수 |

## 프라이버시

- 촬영본은 세션 종료 화면에서 **사진 앱으로 저장하지 않으면 즉시 삭제** — 서버 전송 없음
- 촬영 중 파일은 `Documents/Sessions/`에 **FileProtection.complete**로 저장
- 촬영 중 REC 표시·프리뷰 상시 노출
- 캘린더에는 기록 썸네일만 남고, 설정에서 전체 삭제 가능 (기록·점수는 유지)
- 점수 원장만 로그인 계정에 한해 Firestore로 백업 (영상·썸네일은 제외)
- `PrivacyInfo.xcprivacy` 포함 (UserDefaults / FileTimestamp / DiskSpace 사유 신고)

## 앱스토어 제출 체크리스트

- [ ] 번들 ID·팀 서명 설정, 버전/빌드 번호 확인
- [ ] Firebase 연동 (위 '계정 & 백엔드 연동' 절) — 미연동 시 이메일 가입이 기기 내 폴백으로만 동작
- [ ] Sign in with Apple capability 추가 (Google 로그인 제공 시 심사 필수)
- [ ] Time Sensitive Notifications capability 추가
- [ ] App Store Connect에서 구독 상품 `com.timelock.pro.monthly` 생성 (월 ₩4,400 권장, 그룹: TimeLock Pro)
- [ ] 개인정보 라벨: "데이터가 수집되지 않음" (온디바이스 저장만 함)
- [ ] 심사 노트에 기재: 전면 카메라는 사용자가 명시적으로 시작하는 자기감시 타임랩스 용도이며, 모든 영상은 기기에만 저장됨. 알람은 사용자가 직접 예약한 활동에만 발생.
- [ ] 스크린샷: 홈 타임라인 / 알람 화면 / 세션 REC 링 / 성공캘린더 / 페이월
- [ ] (선택) iOS 26 SDK 채택 시 `ENABLE_ALARMKIT` + AlarmKit capability

## 알려진 제약

- iOS 26 미만에서는 시스템이 앱을 강제 실행할 수 없어, 알림 탭 없이 잠금 화면에 풀스크린 알람을 띄울 수 없습니다 (재알림 4회로 보완, 온보딩에서 고지 권장).
- 시뮬레이터에서는 카메라·통화 감지가 동작하지 않습니다.
- 장시간 세션은 발열·배터리 영향이 있으므로 앱이 밝기 감소 모드와 5% 배터리 안전 종료를 제공합니다.
