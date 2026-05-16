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
    // 중복 발송 방지 — 같은 (session_id, kind, date)는 한 번만
    const { data: logRow } = await supabase
      .from('notification_log')
      .select('id')
      .eq('session_id', t.sessionId)
      .eq('kind', t.kind)
      .eq('target_date', t.date)
      .maybeSingle();
    if (logRow) {
      results.push({ sessionId: t.sessionId, kind: t.kind, skipped: 'already_sent' });
      continue;
    }

    const isToday = t.kind === 'd_day';
    const icon = t.row.type_icon || '📌';
    const titleHead =
      t.kind === 'd_day' ? '오늘 모임 있어요'
      : t.kind === 'd_1' ? '내일 모임 있어요'
      : '3일 뒤 모임 있어요';
    const timePart = t.row.time_str ? ` · ${t.row.time_str}` : '';
    const placePart = t.row.place ? ` @ ${t.row.place}` : '';
    const payload = JSON.stringify({
      title: `${icon} ${titleHead}`,
      body: `${t.row.title}${timePart}${placePart}`,
      tag: `event-${t.sessionId}-${t.kind}`,
      url: `${SITE_URL}/#meet`,
      sessionId: t.sessionId,
      requireInteraction: isToday,
    });

    let sent = 0;
    for (const sub of subs || []) {
      try {
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } } as any,
          payload
        );
        sent++;
      } catch (e: any) {
        // 410 Gone / 404 Not Found → 만료된 구독, 제거
        const status = e?.statusCode || e?.status || 0;
        if (status === 404 || status === 410) expired.push(sub.id);
      }
    }

    await supabase.from('notification_log').insert({
      session_id: t.sessionId,
      kind: t.kind,
      target_date: t.date,
      sent_count: sent,
    });

    totalSent += sent;
    results.push({ sessionId: t.sessionId, kind: t.kind, sent });
  }

  if (expired.length) {
    await supabase.from('push_subscriptions').delete().in('id', expired);
  }

  return new Response(
    JSON.stringify({ ok: true, totalSent, expired: expired.length, results }),
    { headers: { 'Content-Type': 'application/json' } }
  );
});
