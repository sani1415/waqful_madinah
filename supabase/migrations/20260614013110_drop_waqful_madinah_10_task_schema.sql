-- Remove Waqful Madinah (10-task) schema only.
-- Preserves: mdr_*, dept_*, khedmat_*, shared_*, student-photos bucket, send-admin-push edge fn.

-- 1) RPC functions used only by 10-task
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE (n.nspname = 'public' AND p.proname LIKE 'madrasa%')
       OR (n.nspname = 'private' AND p.proname = 'verify_teacher_pin')
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE', r.nspname, r.proname, r.args);
  END LOOP;
END $$;

-- 2) Relational tables (10-task only)
DROP TABLE IF EXISTS public.task_completions CASCADE;
DROP TABLE IF EXISTS public.task_assignments CASCADE;
DROP TABLE IF EXISTS public.quiz_submissions CASCADE;
DROP TABLE IF EXISTS public.quiz_assignees CASCADE;
DROP TABLE IF EXISTS public.quiz_questions CASCADE;
DROP TABLE IF EXISTS public.quizzes CASCADE;
DROP TABLE IF EXISTS public.goals CASCADE;
DROP TABLE IF EXISTS public.academic_history CASCADE;
DROP TABLE IF EXISTS public.teacher_notes CASCADE;
DROP TABLE IF EXISTS public.documents CASCADE;
DROP TABLE IF EXISTS public.daily_schedule_proposals CASCADE;
DROP TABLE IF EXISTS public.daily_schedule_rows CASCADE;
DROP TABLE IF EXISTS public.diary CASCADE;
DROP TABLE IF EXISTS public.student_groups CASCADE;
DROP TABLE IF EXISTS public.pwa_subscriptions CASCADE;
DROP TABLE IF EXISTS public.messages CASCADE;
DROP TABLE IF EXISTS public.tasks CASCADE;
DROP TABLE IF EXISTS public.students CASCADE;
DROP TABLE IF EXISTS public.madrasa_config CASCADE;
DROP TABLE IF EXISTS public.app_kv CASCADE;
DROP TABLE IF EXISTS public.device_push_tokens CASCADE;;
