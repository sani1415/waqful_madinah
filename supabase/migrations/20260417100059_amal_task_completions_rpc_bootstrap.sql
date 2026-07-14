-- Add completions to bootstrap bundles
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
    'completions', (SELECT jsonb_agg(row_to_json(tc)) FROM public.task_completions tc),
    'goals', (SELECT jsonb_agg(row_to_json(g)) FROM public.goals g),
    'quizzes', (SELECT jsonb_agg(row_to_json(q)) FROM (SELECT * FROM public.quizzes ORDER BY created_at) q),
    'quiz_questions', (SELECT jsonb_agg(row_to_json(qq)) FROM (SELECT * FROM public.quiz_questions ORDER BY quiz_id, sort_order) qq),
    'quiz_assignees', (SELECT jsonb_agg(row_to_json(qa)) FROM public.quiz_assignees qa),
    'quiz_submissions', (SELECT jsonb_agg(row_to_json(qs)) FROM public.quiz_submissions qs),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM (SELECT * FROM public.documents ORDER BY uploaded_at DESC) d),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.academic_history ah),
    'teacher_notes', (SELECT jsonb_agg(row_to_json(tn)) FROM public.teacher_notes tn)
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
    'completions', (
      SELECT jsonb_agg(row_to_json(tc))
      FROM public.task_completions tc
      WHERE tc.student_id = v_student.id
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
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.academic_history ah WHERE ah.student_id = v_student.id)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_bootstrap(text, text) TO anon;

-- Completion RPCs (teacher or student)
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_completion(
  p_pin text,
  p_role text,
  p_id text,
  p_task_id text,
  p_student_id text,
  p_date text,
  p_status text,
  p_completed_at timestamptz DEFAULT NULL,
  p_note text DEFAULT ''
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (SELECT 1 FROM public.students WHERE id = p_student_id AND pin = p_pin);
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.task_completions (id, task_id, student_id, comp_date, status, completed_at, note, created_at)
  VALUES (
    p_id, p_task_id, p_student_id,
    NULLIF(p_date,'')::date,
    COALESCE(NULLIF(p_status,''),'done'),
    COALESCE(p_completed_at, now()),
    COALESCE(p_note,''),
    now()
  )
  ON CONFLICT (task_id, student_id, comp_date) DO UPDATE SET
    status = EXCLUDED.status,
    completed_at = EXCLUDED.completed_at,
    note = EXCLUDED.note;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_completion(text, text, text, text, text, text, text, timestamptz, text) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_completion(
  p_pin text,
  p_role text,
  p_task_id text,
  p_student_id text,
  p_date text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (SELECT 1 FROM public.students WHERE id = p_student_id AND pin = p_pin);
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  DELETE FROM public.task_completions
  WHERE task_id = p_task_id AND student_id = p_student_id AND comp_date = NULLIF(p_date,'')::date;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_completion(text, text, text, text, text) TO anon;;
