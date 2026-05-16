// Supabase Edge Function: send-event-reminders
// 매일 pg_cron이 호출 → 오늘(D-day)·내일(D-1) 모임 조회 → Web Push 발송
//
// Required env (Supabase Edge Function Secrets):
//   SUPABASE_URL              자동 주입
//   SUPABASE_SERVICE_ROLE_KEY 자동 주입 (RLS 우회 위해 service role 필요)
//   VAPID_PUBLIC_KEY          BKN_42BLXAEFw1b912ap0ebSZ-fRRmazrY9Hhw5328s5-GsMPg6MOi2eWUewfyLmj6wJIBEtJpp9EYujGoFVZB0
//   VAPID_PRIVATE_KEY         (비공개, supabase secrets set)
//   VAPID_SUBJECT             mailto:admin@choigang-elec.app
//   CRON_SECRET               pg_cron 인증용 임의 토큰
//   SITE_URL                  https://choigang-elec... (알림 클릭 시 열릴 URL)
//
// 호출:
//   POST /functions/v1/send-event-reminders
//   Authorization: Bearer ${CRON_SECRET}
//   Body (optional): {"forceDate":"2026-05-20"}  // 테스트용
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import webpush from 'https://esm.sh/web-push@3.6.7';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY')!;
const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY')!;
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@choigang-elec.app';
const CRON_SECRET = Deno.env.get('CRON_SECRET') || '';
const SITE_URL = Deno.env.get('SITE_URL') || 'https://choigang-elec.vercel.app';

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// KST 기준 오늘 / 내일 yyyy-mm-dd
function ymd(d: Date) {
  const kst = new Date(d.getTime() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  // 인증 (CRON_SECRET이 설정돼 있으면 검증)
  if (CRON_SECRET) {
    const auth = req.headers.get('authorization') || '';
    if (auth !== `Bearer ${CRON_SECRET}`) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 });
    }
  }

  let forceDate: string | null = null;
  try {
    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({}));
      forceDate = body?.forceDate || null;
    }
  } catch (_) {}

  const now = new Date();
  const today = forceDate || ymd(now);
  const tomorrow = forceDate
    ? null
    : ymd(new Date(now.getTime() + 24 * 60 * 60 * 1000));

  // D-3 날짜 계산
  const in3days = forceDate ? null : ymd(new Date(now.getTime() + 3 * 24 * 60 * 60 * 1000));

  // 알림 발송 대상: candidate_dates에 오늘/내일/3일후 포함 + is_active
  const targets: { sessionId: number; kind: 'd_day' | 'd_1' | 'd_3'; date: string; row: any }[] = [];
  const { data: sessions, error } = await supabase
    .from('schedule_sessions')
    .select('id, title, type, type_icon, time_str, place, candidate_dates, is_active')
    .eq('is_active', true);
  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  for (const s of sessions || []) {
    const dates: string[] = s.candidate_dates || [];
    if (dates.includes(today)) targets.push({ sessionId: s.id, kind: 'd_day', date: today, row: s });
    if (tomorrow && dates.includes(tomorrow))
      targets.push({ sessionId: s.id, kind: 'd_1', date: tomorrow, row: s });
    if (in3days && dates.includes(in3days))
      targets.push({ sessionId: s.id, kind: 'd_3', date: in3days, row: s });
  }

  if (targets.length === 0) {
    return new Response(JSON.stringify({ ok: true, sent: 0, message: '발송할 모임 없음' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // 구독자 전체 조회 (서비스 롤이라 RLS 우회)
  const { data: subs, error: subErr } = await supabase
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth, member_name');
  if (subErr) {
    return new Response(JSON.stringify({ error: subErr.message }), { status: 500 });
  }

  let totalSent = 0;
  const expired: number[] = [];
  const results: any[] = [];

  for (const t of targets) {
    // 중복 발송 방지 — atomic lock: 먼저 행을 차지(insert with sent_count=0)하고 성공한 호출만 발송
    // unique (session_id, kind, target_date) 제약 + ignoreDuplicates 옵션
    const { data: claimed, error: claimErr } = await supabase
      .from('notification_log')
      .upsert(
        { session_id: t.sessionId, kind: t.kind, target_date: t.date, sent_count: 0 },
        { onConflict: 'session_id,kind,target_date', ignoreDuplicates: true }
      )
      .select('id');
    if (claimErr) {
      results.push({ sessionId: t.sessionId, kind: t.kind, error: claimErr.message });
      continue;
    }
    if (!claimed || claimed.length === 0) {
      // 다른 호출이 이미 차지함 → 스킵
      results.push({ sessionId: t.sessionId, kind: t.kind, skipped: 'already_sent' });
      continue;
    }
    const logId = claimed[0].id as number;

    const isToday = t.kind === 'd_day';
    const icon = t.row.type_icon || '⚡';
    const dTag =
      t.kind === 'd_day' ? '오늘'
      : t.kind === 'd_1' ? '내일'
      : '3일 뒤';
    const lines: string[] = [];
    if (t.row.time_str) lines.push(`🕘 ${t.row.time_str}`);
    if (t.row.place)    lines.push(`📍 ${t.row.place}`);
    const payload = JSON.stringify({
      title: `${icon} ${dTag} · ${t.row.title}`,
      body: lines.join('\n') || '자세히 보러가기',
      tag: `event-${t.sessionId}-${t.kind}`,
      url: `${SITE_URL}/#meet`,
      sessionId: t.sessionId,
      requireInteraction: isToday,
    });

    let sent = 0;
    let transientFail = 0;
    for (const sub of subs || []) {
      let lastStatus = 0;
      let lastErr: any = null;
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await webpush.sendNotification(
            { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } } as any,
            payload
          );
          sent++;
          lastStatus = 0;
          break;
        } catch (e: any) {
          lastErr = e;
          lastStatus = e?.statusCode || e?.status || 0;
          // 영구 실패: 만료/잘못된 구독 → 즉시 제거, 재시도 안 함
          if (lastStatus === 404 || lastStatus === 410 || lastStatus === 403) {
            expired.push(sub.id);
            break;
          }
          // 일시 실패(5xx, 408, 429, 네트워크): 지수 백오프 후 재시도
          const isTransient = lastStatus === 0 || lastStatus === 408 || lastStatus === 429 || (lastStatus >= 500 && lastStatus < 600);
          if (!isTransient) break;
          if (attempt < 2) await new Promise((r) => setTimeout(r, 300 * Math.pow(2, attempt)));
        }
      }
      if (lastStatus !== 0 && lastStatus !== 404 && lastStatus !== 410 && lastStatus !== 403) {
        transientFail++;
        console.warn('[push] 일시 실패 후 포기:', sub.endpoint?.slice(-12), 'status=', lastStatus, lastErr?.body || '');
      }
    }

    // 실제 발송 카운트 업데이트
    await supabase
      .from('notification_log')
      .update({ sent_count: sent })
      .eq('id', logId);

    totalSent += sent;
    results.push({ sessionId: t.sessionId, kind: t.kind, sent, transientFail });
  }

  if (expired.length) {
    await supabase.from('push_subscriptions').delete().in('id', expired);
  }

  return new Response(
    JSON.stringify({ ok: true, totalSent, expired: expired.length, results }),
    { headers: { 'Content-Type': 'application/json' } }
  );
});
