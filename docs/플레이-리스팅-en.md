# Play 스토어 영어 리스팅 (복붙용)

영어(미국) 스토어 등록정보용 초안. 한국어 리스팅·배포 절차는 `docs/안드로이드-배포-가이드.md` 참고.
Play Console → 성장 → 스토어 등록정보 → **번역 관리 → 번역 추가 → English (United States)** 후
각 칸에 붙여넣는다.

> 글자 수 제한은 Google 기준. 괄호 안은 현재 초안의 실제 길이다.
> 영어 카피는 App Store 리스팅(`docs/스토어-리스팅-en.md`)과 문구를 맞춰 두었다 —
> 한쪽을 고치면 반드시 같이 고칠 것.

## 기본 칸

| 칸 | 제한 | 값 |
|---|---|---|
| 앱 이름 (App name) | 30 | `AngryMoti` (9) |
| 간단한 설명 (Short description) | 80 | `The alarm you can't swipe off. Record a timelapse to dismiss it.` (65) |

간단한 설명 대안:
- `Show up, or it goes on your record. Alarms only a camera can stop.` (67)
- `The only way to stop the alarm is to start recording.` (53)

## 자세한 설명 (Full description, 4000자)

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

Payment is charged to your Google account. Subscriptions renew automatically unless cancelled before the end of the current billing period. Manage or cancel anytime in your Play Store subscription settings.

Terms of Use: https://singlemark.notion.site/Terms-of-Use-English-3be41b10f64b8016ba06e582c2a03caf
Privacy Policy: https://singlemark.notion.site/Privacy-Policy-English-3be41b10f64b80d99cc8d8ed818fc6ec
```

App Store 설명과의 차이는 결제 문단 하나뿐이다 (Apple account/App Store → Google
account/Play Store, 24시간 조항은 Google 정책에 없으므로 제거). 이 문구는 앱 페이월의
구독 고지(`strings.xml`의 `subscription_disclosure`)와 동일한 내용이다.

## 개인정보처리방침 URL (앱 단위 — 언어별 아님)

정책 → 앱 콘텐츠 → 개인정보처리방침: **허브 주소** 하나만 입력한다.

```
https://singlemark.notion.site/Privacy-Policy-3be41b10f64b80788968de130cb0a7d2
```

심사자가 어느 언어로 보든 허브에서 한/영 문서를 모두 찾을 수 있다. 앱 안에서는 기기
언어에 맞는 하위 페이지로 직행한다 — `android/.../ui/SettingsScreens.kt`의 `Legal`.
자세한 구분은 `docs/법무-문서-색인.md`.

## 구독 상품 영어 현지화 ★ iOS와 같은 누락 주의

수익 창출 → 구독 → `com.timelock.pro.monthly` → **번역 추가 (English — United States)**:

| 칸 | 값 |
|---|---|
| 이름 (Name) | `AngryMoti Membership` |
| 혜택/설명 칸 | `More activity slots, no watermark, and Insane mode.` |

가격: 한국 ₩4,400 → 미국 가격을 **$2.99**로 직접 설정한다 (Google 자동 환산은 환율에
따라 어긋나므로 국가별 가격에서 미국만 수동 지정). 금액을 바꾸면 세 곳을 함께 고친다
(이 문서·`docs/스토어-리스팅-en.md`·`docs/terms-of-use-en.md` 6조. 앱 페이월은 Play
Billing 실제 가격 자동 표시).

## 그래픽 자산

| 자산 | 규격 | 값 |
|---|---|---|
| 앱 아이콘 | 512×512 | 언어 무관 — 기존 것 그대로 |
| 그래픽 이미지 (Feature graphic) | 1024×500 | **영어판 별도 필요** — 한국어판에 텍스트가 있다면 영어 텍스트로 교체한 버전을 등록 (텍스트 없는 디자인이면 재사용 가능) |
| 폰 스크린샷 | 2~8장, 각 변 320~3840px, 비율 최대 2:1 | `shots-en` 브랜치의 en 캡처 재활용 (1080×2146 — 비율 1.99:1로 규격 통과) |

스크린샷 추천 구성 (스토어 노출 순서대로):

1. `en-home.png` — 홈 (오늘 활동·스트릭)
2. `en-reservation-new.png` — 활동 예약
3. `en-calendar.png` — 기록 캘린더 + 누적 대시보드
4. `en-paywall.png` — 멤버십 ※ 상품 미로드 상태("Couldn't load subscription options")로
   찍혀 있으므로 **실기기에서 재캡처 필요** (Play 결제는 에뮬레이터 불가)
5. 세션 진행 화면 — **실기기 촬영 필요** (에뮬레이터는 카메라 프리뷰가 검게 나옴)

## 남은 확인 사항

- [ ] 스토어 등록정보에 English (United States) 번역 추가 후 위 칸 전부 입력
- [ ] 구독 상품에 영어 번역 추가 + 미국 가격 $2.99 수동 지정
- [ ] 영어 그래픽 이미지(1024×500) 준비
- [ ] 영어 스크린샷 업로드 (페이월·세션은 실기기 재캡처)
- [ ] 데이터 보안 양식은 언어 무관 — 기존 제출분 그대로, 수정 불필요
