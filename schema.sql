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
-- [PLANNED] 4. MEMBERS  ─ 회원 프로필 (로그인 구현 후 활성화)
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
-- updated_at 자동 갱신 트리거 (LIVE 테이블용)
-- ============================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
-- (schedule_sessions, comments 는 updated_at 컬럼 없어서 트리거 불필요)
