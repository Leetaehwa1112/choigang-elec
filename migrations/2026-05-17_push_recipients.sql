-- ============================================================
-- scheduled_pushes에 수신자 명단 컬럼 추가 (2026-05-17)
-- ============================================================
-- 어드민 푸시 발송 시 누구에게 갔는지 추적하기 위해 recipients TEXT[] 컬럼 추가.
-- send-scheduled-pushes Edge Function이 발송 성공한 endpoint의 member_name을
-- 중복 제거해서 이 컬럼에 저장.
-- ============================================================

alter table public.scheduled_pushes
  add column if not exists recipients text[] default '{}';

-- 검증:
--   select id, title, sent_count, recipients from scheduled_pushes order by id desc limit 5;
