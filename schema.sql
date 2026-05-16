-- ============================================================
-- 최강전기 동창회 · Supabase (PostgreSQL) Schema
-- ============================================================
-- 상태 범례
--   [LIVE]    현재 Supabase에 실제 존재하고 프론트가 사용 중
--   [PLANNED] 추후 구현 예정 (미생성, 주석 처리)
-- ============================================================

create extension if not exists "uuid-ossp";

-- ============================================================
-- [LIVE] 1. SCHEDULE_SESSIONS  ─ 이벤트 / 일정
-- ============================================================
-- 사용처: 이벤트 섹션, 다음 이벤트 슬라이더, 일정잡기 모달
create table if not exists schedule_sessions (
  id              bigserial primary key,
  title           text not null,
  type            text not null,                              -- '술자리','밥자리','번개','정기모임','야외활동','경조사'
  type_icon       text not null default '📌',
  time_str        text,                                       -- "18:00"
  place           text,
  addr            text,
  map_url         text,
  map_provider    text check (map_provider in ('kakao','naver','tmap')),
  memo            text,
  candidate_dates text[] not null default '{}',              -- ["2026-07-05", "2026-07-06"]
  action_url      text,                                       -- 청첩장·링크 URL
  action_label    text,                                       -- 버튼 레이블 ("청첩장", "예약하기" 등)
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);

alter table schedule_sessions enable row level security;
create policy "ss_read"   on schedule_sessions for select using (true);
create policy "ss_insert" on schedule_sessions for insert with check (true);
create policy "ss_update" on schedule_sessions for update using (true);
create policy "ss_delete" on schedule_sessions for delete using (true);

-- ============================================================
-- [LIVE] 2. COMMENTS  ─ 멤버·사진·이벤트 댓글
-- ============================================================
-- 사용처: 멤버 카드, 사진 라이트박스, 결혼식 카드
-- target 예시: "member-이태화", "mem-aildof8i", "meet"
create table if not exists comments (
  id          uuid primary key default uuid_generate_v4(),
  target      text not null,                                  -- 댓글 대상 식별자
  author      text not null,
  content     text not null,
  created_at  timestamptz not null default now()
);

create index if not exists comments_target_idx on comments (target, created_at);

alter table comments enable row level security;
create policy "cmt_read"   on comments for select using (true);
create policy "cmt_insert" on comments for insert with check (true);
create policy "cmt_update" on comments for update using (true);
create policy "cmt_delete" on comments for delete using (true);

-- ============================================================
-- [LIVE] 3. PHOTO_MEMORIES  ─ 추억 사진·영상
-- ============================================================
-- 사용처: 추억 섹션 그리드, 라이트박스
-- 사진: type='photo',  src=Cloudinary URL, is_short=false
-- 영상: type='youtube', src=YouTube video ID, is_short=true/false
create table if not exists photo_memories (
  id          bigserial primary key,
  type        text not null check (type in ('photo','youtube')),
  src         text not null,                                  -- Cloudinary URL 또는 YouTube video ID
  label       text,                                           -- 사진 설명 (라이트박스 상단 표시)
  group_name  text,                                           -- 앨범 이름 ("이은준 청모 🍺", "고등학교 시절 📸")
  is_short    boolean not null default false,                 -- YouTube Shorts 여부
  created_at  timestamptz not null default now()
);

create index if not exists photo_memories_group_idx on photo_memories (group_name, created_at);

alter table photo_memories enable row level security;
create policy "pm_read"   on photo_memories for select using (true);
create policy "pm_insert" on photo_memories for insert with check (true);
create policy "pm_delete" on photo_memories for delete using (true);

-- ============================================================
-- [LIVE] 4. EVENT_RSVPS  ─ 참석/불참
-- ============================================================
-- session_id references schedule_sessions(id)
-- member_name: 이태화·나준민·한동명·이은준·김상현·김하람·김건우
-- status: 'attend' | 'decline'
-- unique(session_id, member_name) → upsert 가능
create table if not exists event_rsvps (
  id          bigserial primary key,
  session_id  bigint not null references schedule_sessions(id) on delete cascade,
  member_name text not null,
  status      text not null check (status in ('attend','decline')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique(session_id, member_name)
);

alter table event_rsvps enable row level security;
create policy "rsvp_read"   on event_rsvps for select using (true);
create policy "rsvp_insert" on event_rsvps for insert with check (true);
create policy "rsvp_update" on event_rsvps for update using (true);
create policy "rsvp_delete" on event_rsvps for delete using (true);

-- schedule_sessions.cover_url (ALTER 별도 실행)
-- ALTER TABLE schedule_sessions ADD COLUMN IF NOT EXISTS cover_url text;

-- photo_memories.uploaded_by (실행 완료 2026-05-17)
-- ALTER TABLE photo_memories ADD COLUMN IF NOT EXISTS uploaded_by text;

-- ============================================================
-- [PLANNED] 5. MEMBERS  ─ 회원 프로필 (로그인 구현 후 활성화)
-- ============================================================
-- create table members (
--   id              uuid primary key default uuid_generate_v4(),
--   auth_id         uuid unique references auth.users(id) on delete cascade,
--   name            text not null,
--   nickname        text,
--   avatar_url      text,
--   bio             text,
--   location        text,
--   job_title       text,
--   company         text,
--   skills          text[] not null default '{}',
--   help_offered    text,
--   kakao_open_url  text,
--   phone           text,
--   phone_public    boolean not null default false,
--   website_url     text,
--   is_admin        boolean not null default false,
--   is_active       boolean not null default true,
--   joined_at       timestamptz not null default now(),
--   updated_at      timestamptz not null default now()
-- );
-- alter table members enable row level security;
-- create policy "members_read" on members for select using (auth.uid() is not null);
-- create policy "members_update_own" on members for update using (auth.uid() = auth_id);

-- ============================================================
-- [PLANNED] 5. EVENTS + EVENT_RSVPS  ─ 공식 모임 RSVP
-- ============================================================
-- schedule_sessions를 현재 사용 중이나, 로그인 구현 후
-- members.id 연동된 공식 RSVP 테이블로 마이그레이션 예정
--
-- create table events ( ... );
-- create table event_rsvps (
--   event_id    uuid references events(id),
--   member_id   uuid references members(id),
--   status      text check (status in ('attend','decline','maybe')),
--   unique (event_id, member_id)
-- );

-- ============================================================
-- [PLANNED] 6. STATUS_POSTS  ─ 근황 피드
-- ============================================================
-- create table status_posts ( ... );
-- create table status_reactions ( ... );

-- ============================================================
-- [PLANNED] 7. ANNOUNCEMENTS  ─ 공지 티커
-- ============================================================
-- create table announcements ( ... );

-- ============================================================
-- [PLANNED] 8. HELP_REQUESTS  ─ 멤버 간 도움 요청
-- ============================================================
-- create table help_requests ( ... );

-- ============================================================
-- [LIVE] 5. PUSH_SUBSCRIPTIONS  ─ Web Push 구독 정보
-- ============================================================
-- 사용처: 모임 D-day 알림 (Edge Function: send-event-reminders)
-- 각 디바이스(브라우저)마다 endpoint 하나씩 발급 — 1유저 N디바이스
create table if not exists push_subscriptions (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  member_name text,                                              -- 표시용 (이태화/나준민/...)
  endpoint    text not null unique,                              -- 브라우저별 푸시 endpoint
  p256dh      text not null,                                     -- 암호화 공개키
  auth        text not null,                                     -- 인증 비밀값
  user_agent  text,
  created_at  timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists push_subs_user_idx on push_subscriptions (user_id);

alter table push_subscriptions enable row level security;
create policy "push_read_own"   on push_subscriptions for select using (auth.uid() = user_id);
create policy "push_insert_own" on push_subscriptions for insert with check (auth.uid() = user_id);
create policy "push_update_own" on push_subscriptions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "push_delete_own" on push_subscriptions for delete using (auth.uid() = user_id);
-- 서비스 롤(Edge Function)은 RLS 우회 → 전체 발송 가능

-- ============================================================
-- [LIVE] 6. NOTIFICATION_LOG  ─ 중복 발송 방지
-- ============================================================
-- 같은 (session_id, kind, target_date)는 하루 한 번만 발송
create table if not exists notification_log (
  id            bigserial primary key,
  session_id    bigint references schedule_sessions(id) on delete cascade,
  kind          text not null,                                    -- 'd_day' | 'd_1' | 'manual'
  target_date   date not null,
  sent_count    int not null default 0,
  created_at    timestamptz not null default now(),
  unique (session_id, kind, target_date)
);

alter table notification_log enable row level security;
create policy "notif_log_read" on notification_log for select using (true);
-- INSERT/UPDATE는 서비스 롤만 (Edge Function)

-- ============================================================
-- [LIVE] 7. SCHEDULED_PUSHES  ─ 어드민 수동 푸시 예약
-- ============================================================
-- 이태화/나준민이 어드민 패널에서 등록한 수동 푸시
-- send_at 도달하면 Edge Function이 발송하고 sent=true로 변경
create table if not exists scheduled_pushes (
  id          bigserial primary key,
  title       text not null,
  body        text not null,
  url         text,                                              -- 클릭 시 열릴 URL (없으면 SITE_URL)
  send_at     timestamptz not null,                              -- UTC 발송 시각
  created_by  text,                                              -- 'admin' 이태화/나준민
  sent        boolean not null default false,
  sent_at     timestamptz,
  sent_count  int not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists scheduled_pushes_pending_idx
  on scheduled_pushes (send_at) where sent = false;

alter table scheduled_pushes enable row level security;

-- 어드민 판별: members 테이블에 role='admin'이거나 이름이 화이트리스트에 있으면 어드민
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from auth.users u
    where u.id = auth.uid()
      and (
        coalesce(u.raw_user_meta_data->>'name','') in ('이태화','나준민')
        or coalesce(u.raw_user_meta_data->>'username','') in ('이태화','나준민')
      )
  );
$$;
grant execute on function public.is_admin() to authenticated, anon;

create policy "sp_read"   on scheduled_pushes for select using (true);
create policy "sp_insert" on scheduled_pushes for insert with check (public.is_admin());
create policy "sp_update_admin" on scheduled_pushes for update using (public.is_admin());
create policy "sp_delete_admin" on scheduled_pushes for delete using (public.is_admin());

-- ============================================================
-- [CRON] pg_cron으로 매일 Edge Function 호출
-- ============================================================
-- 1) 확장 활성화 (Supabase Dashboard → Database → Extensions에서 pg_cron, pg_net 켜기)
-- 2) 아래 SQL 한 번 실행 (PROJECT_REF / CRON_SECRET / 시간 본인 환경에 맞게 수정)
--
-- select cron.schedule(
--   'send-event-reminders-daily',
--   '0 0 * * *',   -- UTC 00:00 = KST 09:00 매일
--   $$
--   select net.http_post(
--     url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/send-event-reminders',
--     headers := jsonb_build_object(
--       'Content-Type', 'application/json',
--       'Authorization', 'Bearer YOUR_CRON_SECRET'
--     ),
--     body := jsonb_build_object('source','pg_cron')
--   );
--   $$
-- );

-- ============================================================
-- [INSTANT PUSH] scheduled_pushes INSERT 시 Edge Function 즉시 호출
-- ============================================================
-- 어드민이 "즉시 발송" 누르면 cron(5분) 안 기다리고 바로 발송되게 하는 트리거
--
-- 1회 셋업:
--   ① 시크릿 저장 (CRON_SECRET, PROJECT_URL)
--      create schema if not exists private;
--      create table if not exists private.app_secrets (key text primary key, value text not null);
--      insert into private.app_secrets(key,value) values
--        ('cron_secret','<YOUR_CRON_SECRET>'),
--        ('project_url','https://mspwdasiewqtwfyngdhy.supabase.co')
--      on conflict (key) do update set value = excluded.value;
--      revoke all on private.app_secrets from public, anon, authenticated;
--
--   ② 아래 함수/트리거 실행 (이 블록 그대로 복붙)

create or replace function private.trigger_scheduled_push()
returns trigger
language plpgsql
security definer
set search_path = public, private, extensions
as $$
declare
  v_url    text;
  v_secret text;
  v_delay  interval;
begin
  -- send_at이 5초 이내(=즉시 발송)일 때만 트리거. 미래 예약은 cron에 맡김.
  v_delay := new.send_at - now();
  if v_delay > interval '5 seconds' then
    return new;
  end if;

  select value into v_url    from private.app_secrets where key = 'project_url';
  select value into v_secret from private.app_secrets where key = 'cron_secret';
  if v_url is null or v_secret is null then
    return new;  -- 시크릿 미설정 시 cron 폴백
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-scheduled-pushes',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_secret
    ),
    body    := jsonb_build_object('forceId', new.id)
  );
  return new;
end;
$$;

drop trigger if exists on_scheduled_push_insert on public.scheduled_pushes;
create trigger on_scheduled_push_insert
  after insert on public.scheduled_pushes
  for each row execute function private.trigger_scheduled_push();

-- ============================================================
-- updated_at 자동 갱신 트리거 (LIVE 테이블용)
-- ============================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
-- (schedule_sessions, comments 는 updated_at 컬럼 없어서 트리거 불필요)
