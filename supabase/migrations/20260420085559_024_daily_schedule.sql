-- 024_daily_schedule.sql
-- Per-student fixed daily schedule (কাজ + সময়); ছাত্র পরিবর্তন প্রস্তাব করতে পারে, শিক্ষক অনুমোদন ছাড়া প্রযোজ্য হয় না।

CREATE TABLE IF NOT EXISTS public.daily_schedule_rows (
  id          TEXT        NOT NULL PRIMARY KEY,
  student_id  TEXT        NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  sort_order  INT         NOT NULL DEFAULT 0,
  task_text   TEXT        NOT NULL DEFAULT '',
  time_text   TEXT        NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS daily_schedule_rows_student_idx ON public.daily_schedule_rows(student_id);

CREATE TABLE IF NOT EXISTS public.daily_schedule_proposals (
  student_id    TEXT        NOT NULL PRIMARY KEY REFERENCES public.students(id) ON DELETE CASCADE,
  proposed_rows JSONB       NOT NULL DEFAULT '[]'::JSONB,
  status        TEXT        NOT NULL CHECK (status IN ('pending', 'rejected')),
  submitted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  teacher_note  TEXT        NOT NULL DEFAULT ''
);

ALTER TABLE public.daily_schedule_rows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_schedule_proposals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "deny_all_direct_ds_rows" ON public.daily_schedule_rows FOR ALL USING (false);
CREATE POLICY "deny_all_direct_ds_prop" ON public.daily_schedule_proposals FOR ALL USING (false);

CREATE OR REPLACE FUNCTION public.madrasa_rel_submit_daily_schedule_proposal(
  p_waqf  TEXT,
  p_pin   TEXT,
  p_rows  JSONB
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_student public.students%ROWTYPE;
BEGIN
  SELECT * INTO v_student FROM public.students WHERE waqf_id = p_waqf AND pin = p_pin;
  IF NOT FOUND THEN RAISE EXCEPTION 'invalid_credentials'; END IF;
  INSERT INTO public.daily_schedule_proposals (student_id, proposed_rows, status, submitted_at, teacher_note)
  VALUES (v_student.id, COALESCE(p_rows, '[]'::JSONB), 'pending', NOW(), '')
  ON CONFLICT (student_id) DO UPDATE SET
    proposed_rows = EXCLUDED.proposed_rows,
    status          = 'pending',
    submitted_at    = NOW(),
    teacher_note    = '';
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_submit_daily_schedule_proposal(TEXT, TEXT, JSONB) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_set_daily_schedule(
  p_teacher_pin TEXT,
  p_student_id  TEXT,
  p_rows        JSONB
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  elem JSONB;
  i    INT := 0;
  new_id TEXT;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  DELETE FROM public.daily_schedule_rows WHERE student_id = p_student_id;
  DELETE FROM public.daily_schedule_proposals WHERE student_id = p_student_id;
  FOR elem IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::JSONB))
  LOOP
    new_id := 'ds_' || REPLACE(gen_random_uuid()::TEXT, '-', '');
    INSERT INTO public.daily_schedule_rows (id, student_id, sort_order, task_text, time_text)
    VALUES (
      new_id,
      p_student_id,
      i,
      COALESCE(elem->>'task', ''),
      COALESCE(elem->>'time', '')
    );
    i := i + 1;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_set_daily_schedule(TEXT, TEXT, JSONB) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_resolve_daily_schedule_proposal(
  p_teacher_pin TEXT,
  p_student_id  TEXT,
  p_approve     BOOLEAN,
  p_note        TEXT DEFAULT ''
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_prop RECORD;
  elem   JSONB;
  i      INT := 0;
  new_id TEXT;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  SELECT * INTO v_prop FROM public.daily_schedule_proposals WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'no_proposal'; END IF;

  IF p_approve THEN
    IF v_prop.status <> 'pending' THEN RAISE EXCEPTION 'not_pending'; END IF;
    DELETE FROM public.daily_schedule_rows WHERE student_id = p_student_id;
    FOR elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_prop.proposed_rows, '[]'::JSONB))
    LOOP
      new_id := 'ds_' || REPLACE(gen_random_uuid()::TEXT, '-', '');
      INSERT INTO public.daily_schedule_rows (id, student_id, sort_order, task_text, time_text)
      VALUES (
        new_id,
        p_student_id,
        i,
        COALESCE(elem->>'task', ''),
        COALESCE(elem->>'time', '')
      );
      i := i + 1;
    END LOOP;
    DELETE FROM public.daily_schedule_proposals WHERE student_id = p_student_id;
  ELSE
    UPDATE public.daily_schedule_proposals
    SET status = 'rejected', teacher_note = COALESCE(p_note, '')
    WHERE student_id = p_student_id AND status = 'pending';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_resolve_daily_schedule_proposal(TEXT, TEXT, BOOLEAN, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_teacher_bootstrap(p_teacher_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT private.verify_teacher_pin(p_teacher_pin) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  RETURN jsonb_build_object(
    'config', (SELECT row_to_json(c) FROM public.madrasa_config c WHERE id = 'singleton'),
    'students', (SELECT jsonb_agg(row_to_json(s)) FROM (SELECT * FROM public.students ORDER BY waqf_id) s),
    'messages', (SELECT jsonb_agg(row_to_json(m)) FROM (SELECT * FROM public.messages ORDER BY sent_at) m),
    'tasks', (SELECT jsonb_agg(row_to_json(t)) FROM (SELECT * FROM public.tasks ORDER BY created_at) t),
    'task_assignments', (SELECT jsonb_agg(row_to_json(ta)) FROM public.task_assignments ta),
    'goals', (SELECT jsonb_agg(row_to_json(g)) FROM public.goals g),
    'quizzes', (SELECT jsonb_agg(row_to_json(q)) FROM (SELECT * FROM public.quizzes ORDER BY created_at) q),
    'quiz_questions', (SELECT jsonb_agg(row_to_json(qq)) FROM (SELECT * FROM public.quiz_questions ORDER BY quiz_id, sort_order) qq),
    'quiz_assignees', (SELECT jsonb_agg(row_to_json(qa)) FROM public.quiz_assignees qa),
    'quiz_submissions', (SELECT jsonb_agg(row_to_json(qs)) FROM public.quiz_submissions qs),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM (SELECT * FROM public.documents ORDER BY uploaded_at DESC) d),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.academic_history ah),
    'teacher_notes', (SELECT jsonb_agg(row_to_json(tn)) FROM public.teacher_notes tn),
    'completions', (
      SELECT COALESCE(jsonb_agg(row_to_json(tc)), '[]'::jsonb)
      FROM (
        SELECT * FROM public.task_completions
        WHERE date >= CURRENT_DATE - INTERVAL '35 days'
        ORDER BY date DESC
      ) tc
    ),
    'diary', (
      SELECT COALESCE(jsonb_agg(row_to_json(d)), '[]'::jsonb)
      FROM (SELECT * FROM public.diary ORDER BY created_at DESC) d
    ),
    'daily_schedule_rows', (
      SELECT COALESCE(jsonb_agg(row_to_json(r)), '[]'::jsonb)
      FROM (SELECT * FROM public.daily_schedule_rows ORDER BY student_id, sort_order) r
    ),
    'daily_schedule_proposals', (
      SELECT COALESCE(jsonb_agg(row_to_json(p)), '[]'::jsonb)
      FROM public.daily_schedule_proposals p
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_teacher_bootstrap(text) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_student_bootstrap(p_waqf text, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_student public.students%ROWTYPE;
BEGIN
  SELECT * INTO v_student FROM public.students
  WHERE waqf_id = p_waqf AND pin = p_pin;
  IF NOT FOUND THEN RAISE EXCEPTION 'invalid_credentials'; END IF;

  RETURN jsonb_build_object(
    'student', row_to_json(v_student),
    'config', (SELECT jsonb_build_object('madrasa', madrasa_name, 'teacher_name', teacher_name)
               FROM public.madrasa_config WHERE id = 'singleton'),
    'messages', (
      SELECT jsonb_agg(row_to_json(m))
      FROM (SELECT * FROM public.messages
            WHERE thread_id = v_student.id OR thread_id = '_bc'
            ORDER BY sent_at) m
    ),
    'tasks', (
      SELECT jsonb_agg(jsonb_build_object(
        'task', row_to_json(t),
        'assignment', row_to_json(ta)
      ))
      FROM public.task_assignments ta
      JOIN public.tasks t ON t.id = ta.task_id
      WHERE ta.student_id = v_student.id
    ),
    'goals', (SELECT jsonb_agg(row_to_json(g)) FROM public.goals g WHERE g.student_id = v_student.id),
    'quizzes', (
      SELECT jsonb_agg(jsonb_build_object(
        'quiz', row_to_json(q),
        'questions', (SELECT jsonb_agg(row_to_json(qq)) FROM (SELECT * FROM public.quiz_questions WHERE quiz_id = q.id ORDER BY sort_order) qq),
        'submission', (SELECT row_to_json(qs) FROM public.quiz_submissions qs WHERE qs.quiz_id = q.id AND qs.student_id = v_student.id)
      ))
      FROM public.quiz_assignees qa
      JOIN public.quizzes q ON q.id = qa.quiz_id
      WHERE qa.student_id = v_student.id
    ),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM (SELECT * FROM public.documents WHERE student_id = v_student.id ORDER BY uploaded_at DESC) d),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.academic_history ah WHERE ah.student_id = v_student.id),
    'completions', (
      SELECT COALESCE(jsonb_agg(row_to_json(tc)), '[]'::jsonb)
      FROM (
        SELECT * FROM public.task_completions
        WHERE student_id = v_student.id
          AND date >= CURRENT_DATE - INTERVAL '35 days'
        ORDER BY date DESC
      ) tc
    ),
    'daily_schedule_rows', (
      SELECT COALESCE(jsonb_agg(row_to_json(r)), '[]'::jsonb)
      FROM (SELECT * FROM public.daily_schedule_rows WHERE student_id = v_student.id ORDER BY sort_order) r
    ),
    'daily_schedule_proposals', (
      SELECT COALESCE(jsonb_agg(row_to_json(p)), '[]'::jsonb)
      FROM public.daily_schedule_proposals p WHERE p.student_id = v_student.id
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_bootstrap(text, text) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_clear_student_data(
  p_teacher_pin text,
  p_student_id  text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  DELETE FROM public.messages         WHERE thread_id  = p_student_id;
  DELETE FROM public.goals            WHERE student_id = p_student_id;
  DELETE FROM public.task_assignments WHERE student_id = p_student_id;
  DELETE FROM public.task_completions WHERE student_id = p_student_id;
  DELETE FROM public.quiz_submissions WHERE student_id = p_student_id;
  DELETE FROM public.quiz_assignees   WHERE student_id = p_student_id;
  DELETE FROM public.documents        WHERE student_id = p_student_id;
  DELETE FROM public.academic_history WHERE student_id = p_student_id;
  DELETE FROM public.teacher_notes    WHERE student_id = p_student_id;
  DELETE FROM public.daily_schedule_rows     WHERE student_id = p_student_id;
  DELETE FROM public.daily_schedule_proposals WHERE student_id = p_student_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_clear_student_data(text, text) TO anon;;
