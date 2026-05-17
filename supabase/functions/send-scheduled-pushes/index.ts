// Supabase Edge Function: send-scheduled-pushes
// 어드민(이태화)이 등록한 scheduled_pushes 중 send_at 이 지난 미발송 건을 발송
//
// 호출: pg_cron이 5분마다 호출
//   POST /functions/v1/send-scheduled-pushes
//   Authorization: Bearer ${CRON_SECRET}
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

Deno.serve(async (req) => {
  if (CRON_SECRET) {
    const auth = req.headers.get('authorization') || '';
    if (auth !== `Bearer ${CRON_SECRET}`) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 });
    }
  }

  // 강제 발송할 특정 id 지정 가능 (어드민 "즉시 발송" 버튼용)
  let forceId: number | null = null;
  try {
    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({}));
      forceId = body?.forceId || null;
    }
  } catch (_) {}

  const nowIso = new Date().toISOString();
  let query = supabase
    .from('scheduled_pushes')
    .select('id, title, body, url, send_at, sent')
    .eq('sent', false);
  if (forceId) {
    query = query.eq('id', forceId);
  } else {
    query = query.lte('send_at', nowIso);
  }

  const { data: pending, error } = await query;
  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
  if (!pending || pending.length === 0) {
    return new Response(JSON.stringify({ ok: true, processed: 0 }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const { data: subs, error: subErr } = await supabase
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth, member_name');
  if (subErr) {
    return new Response(JSON.stringify({ error: subErr.message }), { status: 500 });
  }

  const results: any[] = [];
  const expired: number[] = [];

  for (const p of pending) {
    const payload = JSON.stringify({
      title: p.title,
      body: p.body,
      tag: `scheduled-${p.id}`,
      url: p.url || `${SITE_URL}/`,
      requireInteraction: true,
    });

    let sent = 0;
    const recipientSet = new Set<string>();
    for (const sub of subs || []) {
      try {
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } } as any,
          payload
        );
        sent++;
        if (sub.member_name) recipientSet.add(sub.member_name);
      } catch (e: any) {
        const status = e?.statusCode || e?.status || 0;
        if (status === 404 || status === 410) expired.push(sub.id);
      }
    }
    const recipients = Array.from(recipientSet).sort();

    await supabase
      .from('scheduled_pushes')
      .update({ sent: true, sent_at: new Date().toISOString(), sent_count: sent, recipients })
      .eq('id', p.id);

    results.push({ id: p.id, sent, recipients });
  }

  if (expired.length) {
    await supabase.from('push_subscriptions').delete().in('id', expired);
  }

  return new Response(
    JSON.stringify({ ok: true, processed: results.length, results, expired: expired.length }),
    { headers: { 'Content-Type': 'application/json' } }
  );
});
