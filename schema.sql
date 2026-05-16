-- ============================================================
-- 최강전기 동창회 · Supabase (PostgreSQL) Schema
-- ============================================================
-- 컨셉:
--   - 10명 동기 중 전기 직군은 1명, 나머지는 다 다른 직업
--   - 멤버 패널이 중심: 각자 직업/특기/도와줄 수 있는 것 공개
--   - 근황은 인스타 연동 또는 직접 작성, 두 소스 모두 한 피드로
--   - 도움요청은 별도 게시판 대신 "멤버에게 도움 요청"으로 흡수
-- ============================================================

create extension if not exists "uuid-ossp";

-- ============================================================
-- 1. MEMBERS (회원 · 멤버 패널의 핵심)
-- ============================================================
create table members (
  id              uuid primary key default uuid_generate_v4(),
  auth_id         uuid unique references auth.users(id) on delete cascade,

  -- 기본 프로필
  name            text not null,                  -- 실명
  nickname        text,                            -- 별명 (학창시절 별명 등)
  avatar_url      text,
  bio             text,                            -- 한줄 소개

  -- 위치 · 직업
  location        text,                            -- "서울 강남", "부산 해운대"
  job_title       text,                            -- "프리랜서 디자이너", "한전 KPS 차장"
  company         text,                            -- 회사/소속 (선택)
  industry        text,                            -- "IT/전기/요식업/금융/공무원/자영업..."

  -- 동창회 핵심 ─ 서로 돕는 그물망
  skills          text[] not null default '{}',    -- 내가 잘하는 것: ["포토샵","세무","전기공사","요리"]
  help_offered    text,                            -- "이런 일이면 언제든 연락줘" (자유 서술)
  help_needed     text,                            -- "요즘 이런 거 찾는 중" (선택)

  -- 외부 연동
  instagram_handle text,                           -- "@" 빼고 저장 (예: "kim_choi_99")
  instagram_sync   boolean not null default false, -- 최근 인스타 글을 피드에 자동 가져올지
  kakao_open_url   text,                           -- 카톡 오픈채팅/1:1 링크
  phone            text,                           -- 비공개 가능 (RLS로 본인+admin만)
  phone_public     boolean not null default false, -- 다른 동기에게 번호 공개 여부
  website_url      text,                           -- 개인 블로그/포트폴리오/가게 사이트

  -- 관리
  is_admin        boolean not null default false,
  is_active       boolean not null default true,   -- 비활성(연락두절 등) 표시
  joined_at       timestamptz not null default now(),
  last_seen_at    timestamptz,                     -- 마지막 로그인 (활성 LED 표시용)
  updated_at      timestamptz not null default now()
);

comment on table members is '동창 회원 프로필 (멤버 패널의 핵심 데이터)';

create index on members (is_active);
create index on members (industry);

-- ============================================================
-- 2. MEMBER_TAGS (멤버 검색용 정규화 태그)
-- ============================================================
-- skills 배열만 써도 되지만, 자주 쓰는 태그는 정규화해서 필터링/추천에 사용
create table member_skill_tags (
  member_id   uuid not null references members(id) on delete cascade,
  tag         text not null,                       -- "포토샵", "세무신고", "이사도움" 등
  primary key (member_id, tag)
);

comment on table member_skill_tags is '멤버 특기 태그 (필터/검색용)';

-- ============================================================
-- 3. HELP_REQUESTS (특정 멤버에게 도움 요청)
-- ============================================================
-- 별도 게시판이 아니라 "○○에게 도움 요청 보내기" 형태
-- 멤버 패널에서 [도움 요청] 버튼 클릭 시 생성
create type help_status as enum (
  'pending',     -- 요청됨
  'accepted',    -- 도와주기로 함
  'declined',    -- 거절
  'completed'    -- 도와줌
);

create table help_requests (
  id           uuid primary key default uuid_generate_v4(),
  requester_id uuid not null references members(id) on delete cascade,  -- 요청한 사람
  helper_id    uuid not null references members(id) on delete cascade,  -- 도움 줄 사람

  subject      text not null,                       -- "포토샵으로 명함 디자인 좀 봐줄 수 있어?"
  body         text,
  status       help_status not null default 'pending',

  -- 공개/비공개
  is_public    boolean not null default false,     -- 다른 동기들도 볼 수 있게 할지

  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  updated_at   timestamptz not null default now()
);

comment on table help_requests is '멤버 → 멤버 도움 요청 (1:1, 선택적 공개)';

create index on help_requests (helper_id, status);
create index on help_requests (requester_id);

-- ============================================================
-- 4. EVENTS (모임 일정)
-- ============================================================
-- 목업 기준 필드:
--   title, held_at, location_name, location_url, fee, max_headcount,
--   organizer_id, note, event_type, is_published
--
-- 플로우:
--   1. 주최자(organizer)가 이벤트 생성 (is_published=false 초안)
--   2. 확정 후 is_published=true → 멤버에게 알림
--   3. 멤버들이 RSVP → event_rsvps 에 기록
--   4. 회비 납부 여부는 rsvp.fee_paid 로 추적
-- ============================================================
create type event_type as enum (
  'regular',    -- 정기 동창회
  'flash',      -- 번개 모임
  'ceremony'    -- 경조사 (결혼식·장례 등)
);

create table events (
  id              uuid primary key default uuid_generate_v4(),
  organizer_id    uuid not null references members(id) on delete restrict,

  title           text not null,                    -- "정기 동창회"
  description     text,                             -- 상세 설명 (선택)
  event_type      event_type not null default 'regular',

  held_at         timestamptz not null,             -- 모임 일시
  location_name   text,                             -- "강남 ○○삼겹살 2층 단독룸"
  location_url    text,                             -- 카카오맵 or 네이버지도 링크
  location_address text,                            -- 실 주소 (선택)

  fee             integer,                          -- 회비 (원), null=무료
  max_headcount   integer,                          -- 정원 (null=무제한)
  note            text,                             -- "결혼식 끝나고 바로" 등 메모

  is_published    boolean not null default false,   -- false=초안, true=공개
  rsvp_deadline   timestamptz,                      -- RSVP 마감 (null=당일까지)

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table events is '모임 일정 (정기·번개·경조사)';
create index on events (held_at);
create index on events (is_published, held_at);

-- ============================================================
-- 5. EVENT_RSVPS (참석 여부 + 회비 납부)
-- ============================================================
-- 목업 기준:
--   - 참석(attend) / 불참(decline) 버튼
--   - 참석자 아바타 리스트 표시
--   - 4/6 카운트
--   - 회비 납부 여부 (fee_paid)
-- ============================================================
create type rsvp_status as enum (
  'attend',   -- 참석
  'decline',  -- 불참
  'maybe'     -- 미응답 (기본값)
);

create table event_rsvps (
  id          uuid primary key default uuid_generate_v4(),
  event_id    uuid not null references events(id) on delete cascade,
  member_id   uuid not null references members(id) on delete cascade,

  status      rsvp_status not null default 'maybe',
  memo        text,                                 -- 개인 메모 ("차 가져가서 늦을 것 같음" 등)

  fee_paid    boolean not null default false,       -- 회비 납부 여부
  paid_at     timestamptz,                          -- 납부 시각

  responded_at timestamptz,                         -- 최초 응답 시각
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  unique (event_id, member_id)
);

comment on table event_rsvps is 'RSVP (참석/불참) + 회비 납부 추적';
create index on event_rsvps (event_id, status);
create index on event_rsvps (member_id);

-- 뷰: 다음 모임 카드에 필요한 데이터 한방에
-- 사용처: 메인 페이지 "다음 모임" 섹션
create view next_event_card as
select
  e.id,
  e.title,
  e.event_type,
  e.held_at,
  e.location_name,
  e.location_url,
  e.fee,
  e.note,
  e.max_headcount,
  e.rsvp_deadline,
  m.name  as organizer_name,
  m.phone as organizer_phone,
  -- 참석 확정 수
  count(r.id) filter (where r.status = 'attend')  as attend_count,
  -- 불참 수
  count(r.id) filter (where r.status = 'decline') as decline_count,
  -- 미응답 수
  count(r.id) filter (where r.status = 'maybe')   as maybe_count,
  -- 회비 납부 완료 수
  count(r.id) filter (where r.status = 'attend' and r.fee_paid) as fee_paid_count,
  -- 참석 멤버 정보 (아바타 리스트용 JSON 배열)
  coalesce(
    jsonb_agg(
      jsonb_build_object('id', am.id, 'name', am.name, 'avatar_url', am.avatar_url, 'fee_paid', r.fee_paid)
      order by r.responded_at
    ) filter (where r.status = 'attend'),
    '[]'
  ) as attendees
from events e
join members m on m.id = e.organizer_id
left join event_rsvps r on r.event_id = e.id
left join members am on am.id = r.member_id
where e.is_published = true
  and e.held_at >= now()
group by e.id, m.name, m.phone
order by e.held_at asc
limit 1;

-- ============================================================
-- 6. STATUS_POSTS (근황 · 직접 작성 + 인스타 미러)
-- ============================================================
create type status_source as enum (
  'manual',      -- 사이트에서 직접 작성
  'instagram'    -- 인스타에서 동기화 가져옴
);

create type status_tag as enum (
  'life',         -- 일상
  'work',         -- 일/사업
  'cert',         -- 합격/성취
  'ceremony',     -- 경조사
  'travel',       -- 여행
  'food'          -- 맛집/요리
);

create table status_posts (
  id            uuid primary key default uuid_generate_v4(),
  author_id     uuid not null references members(id) on delete cascade,

  body          text not null,                     -- 본문 (인스타도 캡션 저장)
  tags          status_tag[] not null default '{}',
  image_urls    text[] not null default '{}',

  -- 소스 추적
  source        status_source not null default 'manual',
  external_url  text,                              -- 인스타 원본 글 링크
  external_id   text,                              -- 인스타 미디어 ID (중복 동기화 방지)
  posted_at     timestamptz not null default now(),-- 원본 게시 시각 (인스타는 IG 시각, 직접은 now)

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (source, external_id)                     -- 같은 인스타 글 중복 방지
);

create index on status_posts (author_id, posted_at desc);
create index on status_posts (posted_at desc);

comment on table status_posts is '근황 피드 (직접 작성 + 인스타 미러)';

-- ============================================================
-- 7. STATUS_REACTIONS (⚡)
-- ============================================================
create table status_reactions (
  id          uuid primary key default uuid_generate_v4(),
  post_id     uuid not null references status_posts(id) on delete cascade,
  member_id   uuid not null references members(id) on delete cascade,

  created_at  timestamptz not null default now(),

  unique (post_id, member_id)
);

-- ============================================================
-- 8. COMMENTS (근황 댓글)
-- ============================================================
create table comments (
  id          uuid primary key default uuid_generate_v4(),
  author_id   uuid not null references members(id) on delete cascade,
  post_id     uuid not null references status_posts(id) on delete cascade,

  body        text not null,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index on comments (post_id, created_at);

-- ============================================================
-- 9. ANNOUNCEMENTS (공지/소식 티커)
-- ============================================================
create table announcements (
  id          uuid primary key default uuid_generate_v4(),
  author_id   uuid not null references members(id) on delete cascade,

  body        text not null,                       -- 짧은 한 줄 (티커용)
  link_url    text,                                -- 상세 링크 (선택)
  is_pinned   boolean not null default false,
  expires_at  timestamptz,                         -- 자동 만료 (지나면 티커에서 빠짐)

  created_at  timestamptz not null default now()
);

-- ============================================================
-- 10. MEMORIES (추억 보관함)
-- ============================================================
create table memories (
  id          uuid primary key default uuid_generate_v4(),
  uploader_id uuid not null references members(id) on delete cascade,

  title       text,
  year        smallint,                            -- 2008~현재
  label       text,                                -- "졸업식", "MT" 등
  image_urls  text[] not null default '{}',

  created_at  timestamptz not null default now()
);

create index on memories (year);

-- ============================================================
-- 11. UPDATED_AT 트리거
-- ============================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger trg_members_u        before update on members        for each row execute function set_updated_at();
create trigger trg_events_u         before update on events         for each row execute function set_updated_at();
create trigger trg_event_rsvps_u    before update on event_rsvps    for each row execute function set_updated_at();
create trigger trg_status_posts_u   before update on status_posts   for each row execute function set_updated_at();
create trigger trg_comments_u       before update on comments       for each row execute function set_updated_at();
create trigger trg_help_requests_u  before update on help_requests  for each row execute function set_updated_at();

-- ============================================================
-- 12. 자주 쓰는 뷰
-- ============================================================

-- 멤버 패널 뷰: 각 멤버 + 최근 근황 1건 + 받은 ⚡ 합계
create view member_panel as
select
  m.id, m.name, m.nickname, m.avatar_url, m.bio,
  m.location, m.job_title, m.company, m.industry,
  m.skills, m.help_offered, m.help_needed,
  m.instagram_handle, m.kakao_open_url, m.website_url,
  m.phone_public, m.is_active, m.last_seen_at,
  (
    select jsonb_build_object(
      'id', sp.id, 'body', sp.body,
      'source', sp.source, 'posted_at', sp.posted_at,
      'image_urls', sp.image_urls
    )
    from status_posts sp
    where sp.author_id = m.id
    order by sp.posted_at desc
    limit 1
  ) as latest_status,
  (
    select count(*) from status_reactions r
    join status_posts sp on sp.id = r.post_id
    where sp.author_id = m.id
  ) as total_reactions
from members m
where m.is_active = true;

-- 다가오는 모임 + RSVP 집계
create view upcoming_events as
select
  e.*,
  m.name as organizer_name,
  count(r.id) filter (where r.status = 'attend')  as attend_count,
  count(r.id) filter (where r.status = 'decline') as decline_count,
  count(r.id) filter (where r.status = 'maybe')   as maybe_count
from events e
join members m on m.id = e.organizer_id
left join event_rsvps r on r.event_id = e.id
where e.held_at >= now()
group by e.id, m.name
order by e.held_at asc;

-- 통합 근황 피드 (인스타 + 직접) — 작성자 정보 + 반응/댓글 수
create view status_feed as
select
  sp.id, sp.body, sp.tags, sp.image_urls,
  sp.source, sp.external_url, sp.posted_at,
  m.id          as author_id,
  m.name        as author_name,
  m.avatar_url  as author_avatar,
  m.job_title   as author_job,
  m.location    as author_location,
  m.instagram_handle,
  (select count(*) from status_reactions where post_id = sp.id) as reaction_count,
  (select count(*) from comments where post_id = sp.id)         as comment_count
from status_posts sp
join members m on m.id = sp.author_id
order by sp.posted_at desc;

-- ============================================================
-- 13. 인스타 동기화 메모 (Edge Function에서 호출)
-- ============================================================
-- Supabase Edge Function (cron)에서:
--   1. members 중 instagram_sync = true 인 사람만 조회
--   2. Instagram Graph API (Basic Display)로 최근 미디어 fetch
--   3. status_posts에 (source='instagram', external_id=미디어ID) 로 upsert
--      → unique 제약으로 중복 자동 방지
--   4. 캡션 → body, 미디어 URL → image_urls, permalink → external_url
--
-- 주의: IG Basic Display는 개인 계정 본인 토큰만 가능.
-- 각 멤버가 본인 계정 연동(OAuth) 필요. 별도 테이블에 토큰 저장:
create table instagram_tokens (
  member_id     uuid primary key references members(id) on delete cascade,
  access_token  text not null,                     -- long-lived token (60일)
  ig_user_id    text not null,
  expires_at    timestamptz not null,
  refreshed_at  timestamptz not null default now()
);

comment on table instagram_tokens is '멤버별 인스타그램 OAuth 토큰 (Edge Function이 동기화에 사용)';

-- ============================================================
-- 14. RLS 정책 (요점만 — 실제 적용 시 주석 해제)
-- ============================================================
-- alter table members enable row level security;
-- alter table help_requests enable row level security;
-- alter table instagram_tokens enable row level security;
--
-- -- 회원은 다른 회원 프로필 읽기 가능 (단 phone은 phone_public=true 일 때만 또는 본인)
-- create policy "members readable to authed"
--   on members for select
--   using (auth.uid() is not null);
--
-- -- 본인 프로필만 수정
-- create policy "own profile update"
--   on members for update
--   using (auth.uid() = auth_id);
--
-- -- 도움 요청: 요청자와 도움 줄 사람만 조회 (is_public이면 전체)
-- create policy "help req visibility"
--   on help_requests for select
--   using (
--     is_public
--     or auth.uid() = (select auth_id from members where id = requester_id)
--     or auth.uid() = (select auth_id from members where id = helper_id)
--   );
--
-- -- 인스타 토큰: 본인만
-- create policy "own ig token"
--   on instagram_tokens for all
--   using (auth.uid() = (select auth_id from members where id = member_id));

-- ============================================================
-- 15. 일정잡기 (schedule_dates + schedule_votes)
-- ============================================================
create table if not exists schedule_dates (
  id         bigserial primary key,
  date_str   text not null unique,   -- "2026-07-05"
  date_label text not null,          -- "7/5 (일)"
  created_at timestamptz default now()
);
alter table schedule_dates enable row level security;
create policy "public read"   on schedule_dates for select using (true);
create policy "public insert" on schedule_dates for insert with check (true);
create policy "public delete" on schedule_dates for delete using (true);

create table if not exists schedule_votes (
  id          bigserial primary key,
  date_str    text not null,
  member_name text not null,
  status      text not null check (status in ('available','unavailable')),
  updated_at  timestamptz default now(),
  constraint schedule_votes_unique unique (date_str, member_name)
);
alter table schedule_votes enable row level security;
create policy "public read"   on schedule_votes for select using (true);
create policy "public insert" on schedule_votes for insert with check (true);
create policy "public update" on schedule_votes for update using (true);
create policy "public delete" on schedule_votes for delete using (true);
