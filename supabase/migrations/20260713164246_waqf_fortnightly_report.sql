-- Fortnightly report ("পাক্ষিক বিবরণ") mandatory-lock feature.
-- Scope guard: this migration may reference only public.waqf_* data tables.

ALTER TABLE public.waqf_madrasa_config
  ADD COLUMN IF NOT EXISTS fortnightly_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS fortnightly_interval_days integer NOT NULL DEFAULT 15,
  ADD COLUMN IF NOT EXISTS fortnightly_category_id text,
  ADD COLUMN IF NOT EXISTS fortnightly_questions jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.madrasa_rel_update_fortnightly_config(
  p_teacher_pin text,
  p_enabled boolean,
  p_interval_days integer,
  p_category_id text,
  p_questions jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;

  UPDATE public.waqf_madrasa_config
  SET fortnightly_enabled = COALESCE(p_enabled, false),
      fortnightly_interval_days = GREATEST(COALESCE(p_interval_days, 15), 1),
      fortnightly_category_id = NULLIF(btrim(COALESCE(p_category_id, '')), ''),
      fortnightly_questions = COALESCE(p_questions, '[]'::jsonb),
      updated_at = now()
  WHERE id = 'singleton';
END;
$$;

REVOKE ALL ON FUNCTION public.madrasa_rel_update_fortnightly_config(text, boolean, integer, text, jsonb) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_update_fortnightly_config(text, boolean, integer, text, jsonb) TO anon;

-- Patch student bootstrap so students receive the fortnightly config
-- (previously only madrasa/teacher_name were exposed to students).
CREATE OR REPLACE FUNCTION public.madrasa_rel_student_bootstrap(p_waqf text, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_student public.waqf_students%ROWTYPE;
BEGIN
  SELECT * INTO v_student FROM public.waqf_students
  WHERE waqf_id = p_waqf AND pin = p_pin;
  IF NOT FOUND THEN RAISE EXCEPTION 'invalid_credentials'; END IF;

  RETURN jsonb_build_object(
    'student', row_to_json(v_student),
    'config', (SELECT jsonb_build_object(
                 'madrasa', madrasa_name,
                 'teacher_name', teacher_name,
                 'fortnightly_enabled', fortnightly_enabled,
                 'fortnightly_interval_days', fortnightly_interval_days,
                 'fortnightly_category_id', fortnightly_category_id,
                 'fortnightly_questions', fortnightly_questions
               )
               FROM public.waqf_madrasa_config WHERE id = 'singleton'),
    'messages', (
      SELECT jsonb_agg(row_to_json(m))
      FROM (SELECT * FROM public.waqf_messages
            WHERE thread_id = v_student.id OR thread_id = '_bc'
            ORDER BY sent_at) m
    ),
    'tasks', (
      SELECT jsonb_agg(jsonb_build_object(
        'task', row_to_json(t),
        'assignment', row_to_json(ta)
      ))
      FROM public.waqf_task_assignments ta
      JOIN public.waqf_tasks t ON t.id = ta.task_id
      WHERE ta.student_id = v_student.id
    ),
    'goals', (SELECT jsonb_agg(row_to_json(g)) FROM public.waqf_goals g WHERE g.student_id = v_student.id),
    'quizzes', (
      SELECT jsonb_agg(jsonb_build_object(
        'quiz', row_to_json(q),
        'questions', (SELECT jsonb_agg(row_to_json(qq)) FROM (SELECT * FROM public.waqf_quiz_questions WHERE quiz_id = q.id ORDER BY sort_order) qq),
        'submission', (SELECT row_to_json(qs) FROM public.waqf_quiz_submissions qs WHERE qs.quiz_id = q.id AND qs.student_id = v_student.id)
      ))
      FROM public.waqf_quiz_assignees qa
      JOIN public.waqf_quizzes q ON q.id = qa.quiz_id
      WHERE qa.student_id = v_student.id
    ),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM (SELECT * FROM public.waqf_documents WHERE student_id = v_student.id ORDER BY uploaded_at DESC) d),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.waqf_academic_history ah WHERE ah.student_id = v_student.id),
    'completions', (
      SELECT COALESCE(jsonb_agg(row_to_json(tc)), '[]'::jsonb)
      FROM (
        SELECT * FROM public.waqf_task_completions
        WHERE student_id = v_student.id
          AND comp_date >= CURRENT_DATE - INTERVAL '35 days'
        ORDER BY comp_date DESC
      ) tc
    ),
    'daily_schedule_rows', (
      SELECT COALESCE(jsonb_agg(row_to_json(r)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_daily_schedule_rows WHERE student_id = v_student.id ORDER BY sort_order) r
    ),
    'daily_schedule_proposals', (
      SELECT COALESCE(jsonb_agg(row_to_json(p)), '[]'::jsonb)
      FROM public.waqf_daily_schedule_proposals p WHERE p.student_id = v_student.id
    ),
    'note_categories', (
      SELECT COALESCE(jsonb_agg(row_to_json(c)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_student_note_categories ORDER BY sort_order, created_at) c
    ),
    'student_notes', (
      SELECT COALESCE(jsonb_agg(row_to_json(n)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_student_notes WHERE student_id = v_student.id ORDER BY created_at DESC) n
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_bootstrap(text, text) TO anon;
;
