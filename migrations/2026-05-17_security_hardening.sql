-- ============================================================
-- 보안 강화 마이그레이션 (2026-05-17)
-- ============================================================
-- 이 SQL은 Supabase SQL Editor에서 "Run without RLS" 옵션 켜고 한 번 실행.
--
-- 변경 사항:
--   ① admin_users 테이블 추가 (이름/메타데이터 기반 어드민 판별 → user_id 기반으로 교체)
--   ② is_admin() 재설계 (auth.uid() ∈ admin_users 만 어드민)
--   ③ schedule_sessions / photo_memories / comments / event_rsvps RLS 강화
--   ④ notification_log RLS (서비스 롤만 쓰기) 명시
-- ============================================================

begin;

-- ─── ① admin_users ─────────────────────────────────────────────
create table if not exists public.admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  added_at   timestamptz not null default now()
);
alter table public.admin_users enable row level security;
-- 어드민 본인만 admin_users를 select 가능 (다른 사용자에게 누가 어드민인지 노출 안 함)
drop policy if exists "admin_users_read_self" on public.admin_users;
create policy "admin_users_read_self" on public.admin_users for select
  using (auth.uid() = user_id);
-- insert/update/delete는 서비스 롤만 (Supabase Dashboard SQL Editor에서 직접 추가)

-- ─── 어드민 시드: 기존에 이태화/나준민 이름으로 가입한 유저를 자동 추가 ───
-- (한 번만 실행되도록 on conflict do nothing)
insert into public.admin_users (user_id, display_name)
select u.id,
       coalesce(u.raw_user_meta_data->>'name', u.raw_user_meta_data->>'username')
  from auth.users u
 where coalesce(u.raw_user_meta_data->>'name','') in ('이태화','나준민')
    or coalesce(u.raw_user_meta_data->>'username','') in ('이태화','나준민')
on conflict (user_id) do nothing;

-- ─── ② is_admin() 재설계 ────────────────────────────────────────
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $func$
  select exists (
    select 1 from public.admin_users
     where user_id = auth.uid()
  );
$func$;
grant execute on function public.is_admin() to authenticated, anon;

-- ─── ③ RLS 강화 ─────────────────────────────────────────────────

-- schedule_sessions: 읽기 공개, 쓰기는 어드민만
drop policy if exists "ss_insert" on public.schedule_sessions;
drop policy if exists "ss_update" on public.schedule_sessions;
drop policy if exists "ss_delete" on public.schedule_sessions;
create policy "ss_insert_admin" on public.schedule_sessions for insert
  with check (public.is_admin());
create policy "ss_update_admin" on public.schedule_sessions for update
  using (public.is_admin()) with check (public.is_admin());
create policy "ss_delete_admin" on public.schedule_sessions for delete
  using (public.is_admin());

-- photo_memories: 읽기 공개, 쓰기는 로그인 사용자 (멤버만 가입 가능하므로 OK)
drop policy if exists "pm_insert" on public.photo_memories;
drop policy if exists "pm_delete" on public.photo_memories;
create policy "pm_insert_auth" on public.photo_memories for insert
  with check (auth.uid() is not null);
-- 삭제는 본인 업로드 or 어드민
create policy "pm_delete_owner_or_admin" on public.photo_memories for delete
  using (
    public.is_admin()
    or (uploaded_by is not null
        and uploaded_by = coalesce(
              (auth.jwt() -> 'user_metadata' ->> 'name'),
              (auth.jwt() -> 'user_metadata' ->> 'username')
            ))
  );

-- comments: 읽기 공개, 쓰기는 로그인 사용자만 (익명 도배 차단)
drop policy if exists "cmt_insert" on public.comments;
drop policy if exists "cmt_update" on public.comments;
drop policy if exists "cmt_delete" on public.comments;
create policy "cmt_insert_auth" on public.comments for insert
  with check (auth.uid() is not null);
-- 본인 댓글 or 어드민만 수정/삭제 가능
create policy "cmt_update_owner_or_admin" on public.comments for update
  using (
    public.is_admin()
    or author = coalesce(
         (auth.jwt() -> 'user_metadata' ->> 'name'),
         (auth.jwt() -> 'user_metadata' ->> 'username')
       )
  );
create policy "cmt_delete_owner_or_admin" on public.comments for delete
  using (
    public.is_admin()
    or author = coalesce(
         (auth.jwt() -> 'user_metadata' ->> 'name'),
         (auth.jwt() -> 'user_metadata' ->> 'username')
       )
  );

-- event_rsvps: 읽기 공개, 로그인 사용자만 upsert
drop policy if exists "rsvp_insert" on public.event_rsvps;
drop policy if exists "rsvp_update" on public.event_rsvps;
drop policy if exists "rsvp_delete" on public.event_rsvps;
create policy "rsvp_insert_auth" on public.event_rsvps for insert
  with check (auth.uid() is not null);
create policy "rsvp_update_auth" on public.event_rsvps for update
  using (auth.uid() is not null) with check (auth.uid() is not null);
create policy "rsvp_delete_auth" on public.event_rsvps for delete
  using (auth.uid() is not null);

-- ─── ④ notification_log: 읽기만 공개, 쓰기는 서비스 롤만 ──────────
-- (이미 read 정책만 있고 insert 정책 없음 → service_role만 INSERT 가능. 명시적으로 확인)
-- 만약 옛 insert 정책이 있으면 제거
drop policy if exists "notif_log_insert" on public.notification_log;
drop policy if exists "notif_log_update" on public.notification_log;
drop policy if exists "notif_log_delete" on public.notification_log;

commit;

-- ============================================================
-- 검증 쿼리
-- ============================================================
-- 1. admin_users 확인:
--    select * from public.admin_users;
--    → 이태화, 나준민 두 행 보여야 함 (둘 다 가입돼 있다면)
--
-- 2. is_admin() 동작 확인:
--    select public.is_admin();  -- 본인이 어드민이면 true
--
-- 3. 비어드민 사용자가 schedule_sessions에 insert 시도 → permission denied 나오면 정상
-- ============================================================
