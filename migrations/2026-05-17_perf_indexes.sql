-- ============================================================
-- 성능 인덱스 마이그레이션 (2026-05-17)
-- ============================================================
-- schedule_sessions를 is_active로 필터 + created_at로 정렬하는 쿼리가
-- 메인 로딩 핫패스. 풀 스캔 방지용 복합 인덱스 추가.
-- ============================================================

create index if not exists schedule_sessions_active_created_idx
  on public.schedule_sessions (created_at)
  where is_active = true;

-- 검증:
--   explain analyze
--   select id, title from schedule_sessions
--    where is_active = true order by created_at;
--   → Index Scan using schedule_sessions_active_created_idx 가 나와야 정상
