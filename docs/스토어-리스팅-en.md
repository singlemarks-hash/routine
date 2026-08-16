# App Store 영어 리스팅 (복붙용)

미국(en-US) 스토어프론트용 초안. 한국어 리스팅은 `docs/출시-가이드.md` 1-D 참고.
App Store Connect → 앱 → **언어 추가(English (U.S.))** 후 각 칸에 붙여넣는다.

> 글자 수 제한은 Apple 기준. 괄호 안은 현재 초안의 실제 길이다.

## 앱 정보 (버전 무관 — 언어별 입력)

| 칸 | 제한 | 값 |
|---|---|---|
| 이름 (Name) | 30 | `AngryMoti` (9) |
| 부제 (Subtitle) | 30 | `The only way to stop the alarm` (30) |

부제 대안 (부제는 검색 가중치가 있어 A/B 여지를 남겨둔다):
- `Record to stop the alarm` (24)
- `Alarms you can't just swipe off` (31 — 1자 초과, 줄여야 함)

## 키워드 (100자, 쉼표 구분, 쉼표 뒤 공백 없음)

```
alarm,focus,timelapse,study,routine,habit,pomodoro,timer,accountability,discipline,streak
```
(89자) — 앱 이름·카테고리명(Productivity)은 자동 색인되므로 넣지 않는다.

## 프로모션 텍스트 (170자 — 심사 없이 언제든 교체 가능)

```
Set the time. When the alarm rings, the only way to turn it off is to start recording. Finish the session to earn points; walk away and take the penalty.
```
(152자)

## 설명 (Description, 4000자)

```
AngryMoti is a self-management app with one rule: when your alarm rings, the only way to turn it off is to start a front-camera timelapse.

No snooze. No swipe. You either show up, or it goes on your record.

• Schedule activities — pick a time and the days it repeats
• Dismiss = start recording — miss the 10-minute window and it's logged as a no-show
• Timelapse your session — the whole session becomes a short video, stored only on your device
• Points and penalties — finishing earns points, quitting costs them, all on one calendar
• Streaks — keep showing up and you unlock more activity slots
• Group Challenge (Membership) — gather with an invite code and compete on the same schedule

YOUR RECORDINGS STAY YOURS
Timelapse videos never leave your device. If you don't save one on the results screen, it's deleted automatically. We use on-device face and body detection only to tell whether you're still in front of the camera — frames are processed in memory and discarded immediately, and no facial data is ever stored or transmitted.

MEMBERSHIP
AngryMoti Membership is $2.99/month and includes:
• At least 10 activity slots (free accounts start with 2)
• No timelapse watermark
• Insane mode — no exceptions, 100% focus, 2x points
• Group Challenge
• Every Membership feature we add in the future

Payment is charged to your Apple account. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your App Store account settings.

Terms of Use: https://singlemark.notion.site/Terms-of-Use-English-3be41b10f64b8016ba06e582c2a03caf
Privacy Policy: https://singlemark.notion.site/Privacy-Policy-English-3be41b10f64b80d99cc8d8ed818fc6ec
```

## URL 칸

| 칸 | 값 |
|---|---|
| 지원 URL (Support) | https://singlemark.notion.site/Terms-of-Use-3be41b10f64b80edaf31da1742338b2c |
| 마케팅 URL | (비워둠) |
| 개인정보처리방침 URL | https://singlemark.notion.site/Privacy-Policy-3be41b10f64b80788968de130cb0a7d2 |
| 이용약관(사용자 지정 EULA) | https://singlemark.notion.site/Terms-of-Use-3be41b10f64b80edaf31da1742338b2c |

**URL 칸에는 허브 주소를 넣는다** (언어별 하위 페이지 아님). 심사자가 어느 언어로
보든 양쪽 문서를 찾을 수 있어야 한다. 앱 안에서는 기기 언어에 맞는 하위 페이지로
직행한다 — `TimeLock/TimeLock/Legal.swift`. 자세한 구분은 `docs/법무-문서-색인.md`.

## 구독 상품 영어 현지화 ★ 누락 주의

현재 `com.timelock.pro.monthly`에는 **한국어 현지화만 등록돼 있다.** 영어 스토어프론트
사용자는 구매 시트에서 한국어 상품명을 보게 되므로 반드시 추가한다.

| 칸 | 값 |
|---|---|
| 표시 이름 (Display Name) | `AngryMoti Membership` |
| 설명 (Description) | `More activity slots, no watermark, and Insane mode.` |

가격: 한국 ₩4,400 기준의 Apple 가격 등급 → 미국 **$2.99**. 설명 본문과 앱 페이월
문구가 이 금액을 쓰고 있으니, 등급을 바꾸면 세 곳을 함께 고친다
(스토어 설명 · `docs/terms-of-use-en.md` 6조 · 앱 페이월은 StoreKit 실제 가격 자동 표시).

## 스크린샷 (6.9" 1320×2868, 5장)

Phase 2에서 캡처한 **영어 스크린샷을 재활용**한다. `shots-ios` 브랜치에 en 16장이 있고,
아래 5장이 리스팅용으로 적합하다.

1. `en-05-home-focus` — 홈
2. `en-13-reservation-new` — 활동 예약
3. `en-12-history` — 기록 캘린더
4. `en-15-paywall` — 멤버십
5. 세션 진행 화면 — **실기기 촬영 필요** (시뮬레이터는 카메라가 없어 프리뷰가 검게 나옴)

캡처는 iPhone 16(1178×2556)이라 6.9"(1320×2868) 규격과 다르다 → 업로드 전 리사이즈하거나,
시뮬레이터를 iPhone 16 Pro Max로 바꿔 재캡처한다
(`Screenshots (iOS)` 워크플로의 `-destination` 변경).

## 심사 메모 (App Review Information → Notes)

```
HOW TO TEST
- Tap "Continue as Guest" on the sign-in screen. No account is required to try the core loop.
- To see an alarm fire: create an activity scheduled a few minutes ahead, then leave the app.
- Dismissing the alarm requires starting the front-camera timelapse. On a device without a
  camera (simulator), the recording preview will be black but the flow still proceeds.

CAMERA USAGE
The front camera is used to record a timelapse of the user's own focus session, which is how
the alarm is dismissed. Videos are stored only on the device and are never uploaded. On-device
face/body detection is used solely to detect whether the user is present in front of the camera;
frames are processed in memory and discarded, and no facial data is stored or transmitted.

SUBSCRIPTION
AngryMoti Membership (com.timelock.pro.monthly), $2.99/month auto-renewing. The paywall is
reachable at: My Page > Profile & Subscription > Subscribe.
```

## 남은 확인 사항

- [ ] English (U.S.) 언어 추가 후 위 칸 전부 입력
- [ ] 구독 상품에 영어 현지화 추가 (위 표)
- [ ] 6.9" 영어 스크린샷 5장 업로드 (세션 화면은 실기기)
- [ ] 개인정보처리방침·EULA URL을 **허브 주소로 교체** (기존에 한국어 하위 주소가 적혀 있었음)
