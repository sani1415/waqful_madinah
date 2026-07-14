CREATE TABLE IF NOT EXISTS public.diary (
  id         TEXT        PRIMARY KEY,
  date       TEXT        NOT NULL DEFAULT '',
  time       TEXT        NOT NULL DEFAULT '',
  text       TEXT        NOT NULL DEFAULT '',
  edited     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.diary ENABLE ROW LEVEL SECURITY;
CREATE POLICY "deny_all_direct" ON public.diary FOR ALL USING (false);

CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_diary(
  p_teacher_pin TEXT,
  p_id          TEXT,
  p_date        TEXT,
  p_time        TEXT,
  p_text        TEXT,
  p_edited      TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  INSERT INTO public.diary (id, date, time, text, edited)
  VALUES (p_id, COALESCE(p_date,''), COALESCE(p_time,''), COALESCE(p_text,''), p_edited)
  ON CONFLICT (id) DO UPDATE
    SET date   = EXCLUDED.date,
        time   = EXCLUDED.time,
        text   = EXCLUDED.text,
        edited = EXCLUDED.edited;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_diary(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_diary(
  p_teacher_pin TEXT,
  p_id          TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  DELETE FROM public.diary WHERE id = p_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_diary(TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_get_diary(
  p_teacher_pin TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  SELECT COALESCE(
    jsonb_agg(row_to_json(d)),
    '[]'::JSONB
  ) INTO v_result
  FROM (SELECT * FROM public.diary ORDER BY created_at DESC) d;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_get_diary(TEXT) TO anon;

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
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_teacher_bootstrap(text) TO anon;;
