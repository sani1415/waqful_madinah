-- Phase 1: prefix all legacy Waqf tables with waqf_*.
-- RPC names stay madrasa_rel_* / madrasa_* for Waqf frontend compatibility.
-- Idarah (mdr_*, dept_*, khedmat_*, shared_*) tables are untouched.

-- 1) Rename tables (FK references follow automatically in PostgreSQL)
alter table if exists public.academic_history rename to waqf_academic_history;
alter table if exists public.app_kv rename to waqf_app_kv;
alter table if exists public.daily_schedule_proposals rename to waqf_daily_schedule_proposals;
alter table if exists public.daily_schedule_rows rename to waqf_daily_schedule_rows;
alter table if exists public.device_push_tokens rename to waqf_device_push_tokens;
alter table if exists public.diary rename to waqf_diary;
alter table if exists public.documents rename to waqf_documents;
alter table if exists public.goals rename to waqf_goals;
alter table if exists public.madrasa_config rename to waqf_madrasa_config;
alter table if exists public.messages rename to waqf_messages;
alter table if exists public.pwa_subscriptions rename to waqf_pwa_subscriptions;
alter table if exists public.quiz_assignees rename to waqf_quiz_assignees;
alter table if exists public.quiz_questions rename to waqf_quiz_questions;
alter table if exists public.quiz_submissions rename to waqf_quiz_submissions;
alter table if exists public.quizzes rename to waqf_quizzes;
alter table if exists public.student_groups rename to waqf_student_groups;
alter table if exists public.students rename to waqf_students;
alter table if exists public.task_assignments rename to waqf_task_assignments;
alter table if exists public.task_completions rename to waqf_task_completions;
alter table if exists public.tasks rename to waqf_tasks;
alter table if exists public.teacher_notes rename to waqf_teacher_notes;

comment on table public.waqf_device_push_tokens is
  'Waqf FCM/Capacitor push tokens (student_waqf).';

-- Explicit deny-all policies for tables that had RLS but no named policy
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'waqf_app_kv'
  ) then
    create policy deny_all on public.waqf_app_kv for all using (false);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'waqf_device_push_tokens'
  ) then
    create policy deny_all on public.waqf_device_push_tokens for all using (false);
  end if;
end $$;

-- 2) Patch public/private function bodies that still reference old table names
do $$
declare
  r record;
  def text;
  new_def text;
  tables text[] := array[
    'daily_schedule_proposals',
    'daily_schedule_rows',
    'device_push_tokens',
    'task_assignments',
    'task_completions',
    'quiz_assignees',
    'quiz_submissions',
    'quiz_questions',
    'academic_history',
    'student_groups',
    'teacher_notes',
    'pwa_subscriptions',
    'madrasa_config',
    'documents',
    'messages',
    'students',
    'app_kv',
    'quizzes',
    'goals',
    'tasks',
    'diary'
  ];
  t text;
begin
  for r in
    select
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid) as args,
      p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prokind = 'f'
  loop
    begin
      def := pg_get_functiondef(r.oid);
    exception
      when others then
        continue;
    end;

    new_def := def;
    foreach t in array tables loop
      new_def := replace(new_def, 'public.' || t, 'public.waqf_' || t);
    end loop;

    if new_def is distinct from def then
      execute new_def;
    end if;
  end loop;
end $$;;
