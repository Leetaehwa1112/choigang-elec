# 모임 D-day 푸시 알림 — 1회 설치 가이드

웹 푸시(Web Push)로 모임 당일/전날에 알림이 자동 발송됩니다.
한 번 셋업해두면 이후엔 자동.

---

## 0. 사전 준비

- Supabase 프로젝트(이미 있음)
- Supabase CLI 설치
  ```bash
  brew install supabase/tap/supabase
  supabase login
  ```
- 프로젝트 디렉터리에서 프로젝트 연결
  ```bash
  cd /Users/itaehwa/Downloads/최강전기
  supabase link --project-ref <YOUR_PROJECT_REF>
  ```
  (PROJECT_REF는 Supabase 대시보드 URL의 `app.supabase.com/project/<여기>` 부분)

---

## 1. DB 스키마 적용

Supabase 대시보드 → SQL Editor에서 `schema.sql`의 아래 두 테이블을 실행:

- `push_subscriptions`
- `notification_log`

(이미 `schema.sql`에 추가돼 있습니다.)

---

## 2. Supabase Extension 활성화

Supabase 대시보드 → **Database → Extensions**에서 다음 두 개 켜기:

- `pg_cron`  (스케줄러)
- `pg_net`   (HTTP 호출)

---

## 3. VAPID 키 (이미 생성됨)

```
Public:  BKN_42BLXAEFw1b912ap0ebSZ-fRRmazrY9Hhw5328s5-GsMPg6MOi2eWUewfyLmj6wJIBEtJpp9EYujGoFVZB0
Private: bQ95nBLZ0sd6bC4t7lMPgEp-OAkNpEmSDDNpMoKd2FA
```

- **Public**: `index.html`에 이미 박혀있음 (공개 OK)
- **Private**: 절대 git에 올리지 말고 아래 secret으로만 저장

---

## 4. Edge Function 시크릿 등록

```bash
# 임의 토큰 생성 (pg_cron 인증용)
CRON_SECRET=$(openssl rand -hex 32)
echo "CRON_SECRET=$CRON_SECRET"   # 기록해두세요 — 6단계에서 SQL에 넣음

supabase secrets set \
  VAPID_PUBLIC_KEY='BKN_42BLXAEFw1b912ap0ebSZ-fRRmazrY9Hhw5328s5-GsMPg6MOi2eWUewfyLmj6wJIBEtJpp9EYujGoFVZB0' \
  VAPID_PRIVATE_KEY='bQ95nBLZ0sd6bC4t7lMPgEp-OAkNpEmSDDNpMoKd2FA' \
  VAPID_SUBJECT='mailto:admin@choigang-elec.app' \
  CRON_SECRET="$CRON_SECRET" \
  SITE_URL='https://choigang-elec.vercel.app'
```

`SITE_URL`은 실제 배포 URL로 바꿔주세요 (알림 클릭 시 열릴 페이지).

---

## 5. Edge Function 배포

```bash
supabase functions deploy send-event-reminders --no-verify-jwt
```

`--no-verify-jwt`는 pg_cron이 JWT 없이 호출할 수 있게 (자체 `CRON_SECRET`으로 인증함).

---

## 6. pg_cron 스케줄 등록

Supabase SQL Editor에서 (PROJECT_REF, CRON_SECRET 본인 값으로 교체):

```sql
select cron.schedule(
  'send-event-reminders-daily',
  '0 0 * * *',   -- UTC 00:00 = KST 09:00 매일
  $$
  select net.http_post(
    url := 'https://<YOUR_PROJECT_REF>.supabase.co/functions/v1/send-event-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <YOUR_CRON_SECRET>'
    ),
    body := jsonb_build_object('source','pg_cron')
  );
  $$
);
```

확인:
```sql
select * from cron.job;
```

삭제하고 다시 등록하려면:
```sql
select cron.unschedule('send-event-reminders-daily');
```

---

## 7. 동작 테스트

수동 호출로 즉시 발송 가능 (특정 날짜의 모임을 D-day로 가정):

```bash
curl -X POST \
  https://<YOUR_PROJECT_REF>.supabase.co/functions/v1/send-event-reminders \
  -H "Authorization: Bearer <YOUR_CRON_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{"forceDate":"2026-07-05"}'
```

응답 예시:
```json
{"ok":true,"totalSent":3,"expired":0,"results":[{"sessionId":12,"kind":"d_day","sent":3}]}
```

---

## 8. 사용자 쪽 (자동)

1. 로그인 후 화면 하단 "🔔 모임 알림 받기" 배너 → **허용**
2. 브라우저가 권한 요청 → 허용
3. 구독 정보가 `push_subscriptions`에 저장됨
4. 매일 KST 09:00에 D-day/D-1 모임 자동 발송

### iOS 사용자 주의사항
- Safari 16.4+ (2023년 3월 이후)
- 게이트의 "앱 다운로드"로 홈 화면에 추가 후 **앱 아이콘으로 실행**해야 푸시 가능
- 일반 Safari 탭에서는 푸시 수신 불가 (애플 정책)

---

## 9. 트러블슈팅

- **알림이 안 와요** — 브라우저 권한, `push_subscriptions` 테이블 행 존재 여부, Edge Function 로그(`supabase functions logs send-event-reminders`) 확인
- **iOS에서 권한 배너가 안 보여요** — 홈화면에 추가하고 앱 아이콘으로 다시 실행
- **같은 날 두 번 발송** — `notification_log`가 중복 차단함. 강제 재발송 시 해당 row 삭제 후 재호출
- **VAPID 키 분실 시** — `npx web-push generate-vapid-keys`로 재생성, 모든 구독자 재등록 필요(기존 endpoint는 새 키로는 못 보냄)

---

## 10. 발송 시점 조정

`pg_cron` 스케줄 변경으로 가능:

| 표현 | 발송 시간 (KST) |
|---|---|
| `0 0 * * *` | 매일 09:00 |
| `0 22 * * *` | 매일 07:00 (전날 22:00 UTC) |
| `0 11 * * *` | 매일 20:00 (저녁) |

또는 함수 본문의 KST 변환 로직을 수정.
