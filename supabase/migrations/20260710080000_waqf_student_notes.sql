-- Student daily notes (বিবরণ) + teacher-managed categories
-- Scope: public.waqf_* only

CREATE TABLE IF NOT EXISTS public.waqf_student_note_categories (
  id         TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  sort_order INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.waqf_student_notes (
  id          TEXT PRIMARY KEY,
  student_id  TEXT NOT NULL REFERENCES public.waqf_students(id) ON DELETE CASCADE,
  category_id TEXT NOT NULL DEFAULT 'general',
  note_date   TEXT NOT NULL DEFAULT '',
  note_time   TEXT NOT NULL DEFAULT '',
  text        TEXT NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS waqf_student_notes_student_idx
  ON public.waqf_student_notes(student_id, created_at DESC);
CREATE INDEX IF NOT EXISTS waqf_student_notes_cat_idx
  ON public.waqf_student_notes(category_id);

ALTER TABLE public.waqf_student_note_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waqf_student_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deny_all_direct" ON public.waqf_student_note_categories;
CREATE POLICY "deny_all_direct" ON public.waqf_student_note_categories FOR ALL USING (false);
DROP POLICY IF EXISTS "deny_all_direct" ON public.waqf_student_notes;
CREATE POLICY "deny_all_direct" ON public.waqf_student_notes FOR ALL USING (false);

INSERT INTO public.waqf_student_note_categories (id, label, sort_order) VALUES
  ('general', 'সাধারণ', 0),
  ('matbakh', 'মাতবাখের দরস', 1),
  ('tajriba', 'তাজেরেবা', 2)
ON CONFLICT (id) DO NOTHING;

-- ── Categories (teacher) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_note_category(
  p_teacher_pin TEXT,
  p_id TEXT,
  p_label TEXT,
  p_sort_order INT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_sort INT;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  IF btrim(COALESCE(p_id, '')) = '' THEN RAISE EXCEPTION 'invalid_id'; END IF;
  IF btrim(COALESCE(p_label, '')) = '' THEN RAISE EXCEPTION 'invalid_label'; END IF;

  IF p_sort_order IS NULL THEN
    SELECT COALESCE(MAX(sort_order), -1) + 1 INTO v_sort
    FROM public.waqf_student_note_categories;
  ELSE
    v_sort := p_sort_order;
  END IF;

  INSERT INTO public.waqf_student_note_categories (id, label, sort_order)
  VALUES (p_id, btrim(p_label), v_sort)
  ON CONFLICT (id) DO UPDATE
    SET label = EXCLUDED.label,
        sort_order = COALESCE(p_sort_order, public.waqf_student_note_categories.sort_order);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_note_category(TEXT, TEXT, TEXT, INT) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_note_category(
  p_teacher_pin TEXT,
  p_id TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  IF p_id = 'general' THEN RAISE EXCEPTION 'cannot_delete_default'; END IF;

  UPDATE public.waqf_student_notes
  SET category_id = 'general'
  WHERE category_id = p_id;

  DELETE FROM public.waqf_student_note_categories WHERE id = p_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_note_category(TEXT, TEXT) TO anon;

-- ── Notes (student PIN, same pattern as goals) ─────────────
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_student_note(
  p_pin TEXT,
  p_student_id TEXT,
  p_note JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  v_ok := EXISTS (
    SELECT 1 FROM public.waqf_students
    WHERE id = p_student_id AND pin = p_pin
  );
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.waqf_student_notes (
    id, student_id, category_id, note_date, note_time, text
  ) VALUES (
    p_note->>'id',
    p_student_id,
    COALESCE(NULLIF(btrim(p_note->>'category_id'), ''), 'general'),
    COALESCE(p_note->>'date', ''),
    COALESCE(p_note->>'time', ''),
    COALESCE(p_note->>'text', '')
  )
  ON CONFLICT (id) DO UPDATE SET
    category_id = EXCLUDED.category_id,
    note_date   = EXCLUDED.note_date,
    note_time   = EXCLUDED.note_time,
    text        = EXCLUDED.text;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_student_note(TEXT, TEXT, JSONB) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_student_note(
  p_pin TEXT,
  p_student_id TEXT,
  p_note_id TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  v_ok := EXISTS (
    SELECT 1 FROM public.waqf_students
    WHERE id = p_student_id AND pin = p_pin
  );
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  DELETE FROM public.waqf_student_notes
  WHERE id = p_note_id AND student_id = p_student_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_student_note(TEXT, TEXT, TEXT) TO anon;

-- Teacher may delete a student's note (profile cleanup)
CREATE OR REPLACE FUNCTION public.madrasa_rel_teacher_delete_student_note(
  p_teacher_pin TEXT,
  p_note_id TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  DELETE FROM public.waqf_student_notes WHERE id = p_note_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_teacher_delete_student_note(TEXT, TEXT) TO anon;

-- ── Bootstrap patches ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.madrasa_rel_teacher_bootstrap(p_teacher_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT private.verify_teacher_pin(p_teacher_pin) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  RETURN jsonb_build_object(
    'config', (SELECT row_to_json(c) FROM public.waqf_madrasa_config c WHERE id = 'singleton'),
    'students', (SELECT jsonb_agg(row_to_json(s)) FROM (SELECT * FROM public.waqf_students ORDER BY waqf_id) s),
    'messages', (SELECT jsonb_agg(row_to_json(m)) FROM (SELECT * FROM public.waqf_messages ORDER BY sent_at) m),
    'tasks', (SELECT jsonb_agg(row_to_json(t)) FROM (SELECT * FROM public.waqf_tasks ORDER BY created_at) t),
    'task_assignments', (SELECT jsonb_agg(row_to_json(ta)) FROM public.waqf_task_assignments ta),
    'goals', (SELECT jsonb_agg(row_to_json(g)) FROM public.waqf_goals g),
    'quizzes', (SELECT jsonb_agg(row_to_json(q)) FROM (SELECT * FROM public.waqf_quizzes ORDER BY created_at) q),
    'quiz_questions', (SELECT jsonb_agg(row_to_json(qq)) FROM (SELECT * FROM public.waqf_quiz_questions ORDER BY quiz_id, sort_order) qq),
    'quiz_assignees', (SELECT jsonb_agg(row_to_json(qa)) FROM public.waqf_quiz_assignees qa),
    'quiz_submissions', (SELECT jsonb_agg(row_to_json(qs)) FROM public.waqf_quiz_submissions qs),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM (SELECT * FROM public.waqf_documents ORDER BY uploaded_at DESC) d),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.waqf_academic_history ah),
    'teacher_notes', (SELECT jsonb_agg(row_to_json(tn)) FROM public.waqf_teacher_notes tn),
    'completions', (
      SELECT COALESCE(jsonb_agg(row_to_json(tc)), '[]'::jsonb)
      FROM (
        SELECT * FROM public.waqf_task_completions
        WHERE comp_date >= CURRENT_DATE - INTERVAL '35 days'
        ORDER BY comp_date DESC
      ) tc
    ),
    'diary', (
      SELECT COALESCE(jsonb_agg(row_to_json(d)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_diary ORDER BY created_at DESC) d
    ),
    'daily_schedule_rows', (
      SELECT COALESCE(jsonb_agg(row_to_json(r)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_daily_schedule_rows ORDER BY student_id, sort_order) r
    ),
    'daily_schedule_proposals', (
      SELECT COALESCE(jsonb_agg(row_to_json(p)), '[]'::jsonb)
      FROM public.waqf_daily_schedule_proposals p
    ),
    'note_categories', (
      SELECT COALESCE(jsonb_agg(row_to_json(c)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_student_note_categories ORDER BY sort_order, created_at) c
    ),
    'student_notes', (
      SELECT COALESCE(jsonb_agg(row_to_json(n)), '[]'::jsonb)
      FROM (SELECT * FROM public.waqf_student_notes ORDER BY created_at DESC) n
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_teacher_bootstrap(text) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_student_bootstrap(p_waqf text, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_student public.waqf_students%ROWTYPE;
BEGIN
  SELECT * INTO v_student FROM public.waqf_students
  WHERE waqf_id = p_waqf AND pin = p_pin;
  IF NOT FOUND THEN RAISE EXCEPTION 'invalid_credentials'; END IF;

  RETURN jsonb_build_object(
    'student', row_to_json(v_student),
    'config', (SELECT jsonb_build_object('madrasa', madrasa_name, 'teacher_name', teacher_name)
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

CREATE OR REPLACE FUNCTION public.madrasa_rel_clear_student_data(
  p_teacher_pin text,
  p_student_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  DELETE FROM public.waqf_messages         WHERE thread_id  = p_student_id;
  DELETE FROM public.waqf_goals            WHERE student_id = p_student_id;
  DELETE FROM public.waqf_task_assignments WHERE student_id = p_student_id;
  DELETE FROM public.waqf_task_completions WHERE student_id = p_student_id;
  DELETE FROM public.waqf_quiz_submissions WHERE student_id = p_student_id;
  DELETE FROM public.waqf_quiz_assignees   WHERE student_id = p_student_id;
  DELETE FROM public.waqf_documents        WHERE student_id = p_student_id;
  DELETE FROM public.waqf_academic_history WHERE student_id = p_student_id;
  DELETE FROM public.waqf_teacher_notes    WHERE student_id = p_student_id;
  DELETE FROM public.waqf_daily_schedule_rows     WHERE student_id = p_student_id;
  DELETE FROM public.waqf_daily_schedule_proposals WHERE student_id = p_student_id;
  DELETE FROM public.waqf_student_notes    WHERE student_id = p_student_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_clear_student_data(text, text) TO anon;
