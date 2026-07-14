-- ══════════════════════════════════════════════
-- 007_relational_rls.sql
-- সব নতুন table-এ RLS চালু, direct REST বন্ধ
-- ══════════════════════════════════════════════

ALTER TABLE public.madrasa_config     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.students           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_assignments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goals              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quizzes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_questions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_assignees     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_submissions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.academic_history   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.teacher_notes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pwa_subscriptions  ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'madrasa_config','students','messages','tasks','task_assignments',
    'goals','quizzes','quiz_questions','quiz_assignees','quiz_submissions',
    'documents','academic_history','teacher_notes','pwa_subscriptions'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS deny_all ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY deny_all ON public.%I FOR ALL TO anon USING (false)',
      t
    );
  END LOOP;
END;
$$;;
