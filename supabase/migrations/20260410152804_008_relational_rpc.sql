-- ══════════════════════════════════════════════
-- 008_relational_rpc.sql
-- PIN-gated RPC functions — relational version
-- ══════════════════════════════════════════════

-- Helper: teacher PIN verify
CREATE OR REPLACE FUNCTION private.verify_teacher_pin(p_pin text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.madrasa_config WHERE id = 'singleton' AND teacher_pin = p_pin
  );
END;
$$;

-- ── PUBLIC BRANDING (PIN ছাড়া) ────────────────
CREATE OR REPLACE FUNCTION public.madrasa_rel_public_branding()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_row public.madrasa_config%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.madrasa_config WHERE id = 'singleton';
  RETURN jsonb_build_object('madrasa', COALESCE(v_row.madrasa_name, 'Waqful Madinah'));
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_public_branding() TO anon;

-- ── STUDENT LOCK HINTS (PIN ছাড়া) ─────────────
CREATE OR REPLACE FUNCTION public.madrasa_rel_student_lock_hints()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT jsonb_agg(jsonb_build_object(
      'id', s.id,
      'waqfId', s.waqf_id,
      'name', s.name,
      'unreadCount', (
        SELECT COUNT(*) FROM public.messages m
        WHERE m.thread_id = s.id AND m.role = 'out' AND m.is_read = false
      )
    ))
    FROM public.students s
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_lock_hints() TO anon;

-- ── TEACHER BOOTSTRAP ──────────────────────────
CREATE OR REPLACE FUNCTION public.madrasa_rel_teacher_bootstrap(p_teacher_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT private.verify_teacher_pin(p_teacher_pin) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  RETURN jsonb_build_object(
    'config', (SELECT row_to_json(c) FROM public.madrasa_config c WHERE id = 'singleton'),
    'students', (SELECT jsonb_agg(row_to_json(s)) FROM public.students s ORDER BY s.waqf_id),
    'messages', (SELECT jsonb_agg(row_to_json(m)) FROM public.messages m ORDER BY m.sent_at),
    'tasks', (SELECT jsonb_agg(row_to_json(t)) FROM public.tasks t ORDER BY t.created_at),
    'task_assignments', (SELECT jsonb_agg(row_to_json(ta)) FROM public.task_assignments ta),
    'goals', (SELECT jsonb_agg(row_to_json(g)) FROM public.goals g),
    'quizzes', (SELECT jsonb_agg(row_to_json(q)) FROM public.quizzes q ORDER BY q.created_at),
    'quiz_questions', (SELECT jsonb_agg(row_to_json(qq)) FROM public.quiz_questions qq ORDER BY qq.quiz_id, qq.sort_order),
    'quiz_assignees', (SELECT jsonb_agg(row_to_json(qa)) FROM public.quiz_assignees qa),
    'quiz_submissions', (SELECT jsonb_agg(row_to_json(qs)) FROM public.quiz_submissions qs),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM public.documents d ORDER BY d.uploaded_at DESC),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.academic_history ah),
    'teacher_notes', (SELECT jsonb_agg(row_to_json(tn)) FROM public.teacher_notes tn)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_teacher_bootstrap(text) TO anon;

-- ── STUDENT BOOTSTRAP ──────────────────────────
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
      FROM public.messages m
      WHERE m.thread_id = v_student.id OR m.thread_id = '_bc'
      ORDER BY m.sent_at
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
        'questions', (SELECT jsonb_agg(row_to_json(qq)) FROM public.quiz_questions qq WHERE qq.quiz_id = q.id ORDER BY qq.sort_order),
        'submission', (SELECT row_to_json(qs) FROM public.quiz_submissions qs WHERE qs.quiz_id = q.id AND qs.student_id = v_student.id)
      ))
      FROM public.quiz_assignees qa
      JOIN public.quizzes q ON q.id = qa.quiz_id
      WHERE qa.student_id = v_student.id
    ),
    'documents', (SELECT jsonb_agg(row_to_json(d)) FROM public.documents d WHERE d.student_id = v_student.id ORDER BY d.uploaded_at DESC),
    'academic_history', (SELECT jsonb_agg(row_to_json(ah)) FROM public.academic_history ah WHERE ah.student_id = v_student.id)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_bootstrap(text, text) TO anon;

-- Student upsert
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_student(
  p_teacher_pin text, p_student jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  INSERT INTO public.students (id, waqf_id, name, cls, roll, pin, color, note,
    father_name, father_occupation, contact, district, upazila, blood_group, enrollment_date)
  VALUES (
    p_student->>'id', p_student->>'waqf_id', p_student->>'name', p_student->>'cls',
    p_student->>'roll', p_student->>'pin', p_student->>'color', p_student->>'note',
    p_student->>'father_name', p_student->>'father_occupation', p_student->>'contact',
    p_student->>'district', p_student->>'upazila', p_student->>'blood_group',
    NULLIF(p_student->>'enrollment_date', '')::date
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name, cls = EXCLUDED.cls, roll = EXCLUDED.roll,
    pin = EXCLUDED.pin, note = EXCLUDED.note,
    father_name = EXCLUDED.father_name, father_occupation = EXCLUDED.father_occupation,
    contact = EXCLUDED.contact, district = EXCLUDED.district,
    upazila = EXCLUDED.upazila, blood_group = EXCLUDED.blood_group,
    enrollment_date = EXCLUDED.enrollment_date;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_student(text, jsonb) TO anon;

-- Student delete
CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_student(
  p_teacher_pin text, p_student_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  DELETE FROM public.students WHERE id = p_student_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_student(text, text) TO anon;

-- Message insert
CREATE OR REPLACE FUNCTION public.madrasa_rel_insert_message(
  p_pin text, p_role text, p_message jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (
      SELECT 1 FROM public.students
      WHERE waqf_id = (p_message->>'thread_id_waqf') AND pin = p_pin
    );
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.messages (id, thread_id, role, type, text, extra, is_read, sent_at)
  VALUES (
    p_message->>'id',
    p_message->>'thread_id',
    p_message->>'role',
    COALESCE(p_message->>'type', 'text'),
    COALESCE(p_message->>'text', ''),
    COALESCE((p_message->'extra')::jsonb, '{}'::jsonb),
    COALESCE((p_message->>'is_read')::boolean, false),
    COALESCE((p_message->>'sent_at')::timestamptz, now())
  );
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_insert_message(text, text, jsonb) TO anon;

-- Mark messages read
CREATE OR REPLACE FUNCTION public.madrasa_rel_mark_messages_read(
  p_pin text, p_role text, p_thread_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (SELECT 1 FROM public.students WHERE id = p_thread_id AND pin = p_pin);
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  UPDATE public.messages SET is_read = true
  WHERE thread_id = p_thread_id
    AND role = (CASE WHEN p_role = 'teacher' THEN 'in' ELSE 'out' END);
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_mark_messages_read(text, text, text) TO anon;

-- Task upsert
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_task(
  p_teacher_pin text, p_task jsonb, p_assignee_ids jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_sid text;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  INSERT INTO public.tasks (id, title, description, type, deadline, created_at)
  VALUES (
    p_task->>'id', p_task->>'title', COALESCE(p_task->>'description', ''),
    COALESCE(p_task->>'type', 'onetime'), NULLIF(p_task->>'deadline', '')::date,
    COALESCE(NULLIF(p_task->>'created_at','')::date, CURRENT_DATE)
  )
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title, description = EXCLUDED.description,
    type = EXCLUDED.type, deadline = EXCLUDED.deadline;

  FOR v_sid IN SELECT jsonb_array_elements_text(p_assignee_ids) LOOP
    INSERT INTO public.task_assignments (id, task_id, student_id, status)
    VALUES (gen_random_uuid()::text, p_task->>'id', v_sid, 'pending')
    ON CONFLICT (task_id, student_id) DO NOTHING;
  END LOOP;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_task(text, jsonb, jsonb) TO anon;

-- Task status update
CREATE OR REPLACE FUNCTION public.madrasa_rel_update_task_status(
  p_pin text, p_role text, p_task_id text, p_student_id text, p_status text,
  p_completed_date text DEFAULT NULL, p_completed_time text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (SELECT 1 FROM public.students WHERE id = p_student_id AND pin = p_pin);
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  UPDATE public.task_assignments
  SET status = p_status,
      completed_date = NULLIF(p_completed_date, '')::date,
      completed_time = p_completed_time
  WHERE task_id = p_task_id AND student_id = p_student_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_update_task_status(text, text, text, text, text, text, text) TO anon;

-- Goal upsert
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_goal(
  p_pin text, p_student_id text, p_goal jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean;
BEGIN
  v_ok := EXISTS (SELECT 1 FROM public.students WHERE id = p_student_id AND pin = p_pin);
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.goals (id, student_id, title, cat, deadline, note, done, created_at)
  VALUES (
    p_goal->>'id', p_student_id, p_goal->>'title',
    COALESCE(p_goal->>'cat', 'other'),
    NULLIF(p_goal->>'deadline', '')::date,
    COALESCE(p_goal->>'note', ''),
    COALESCE((p_goal->>'done')::boolean, false),
    COALESCE(NULLIF(p_goal->>'created_at','')::date, CURRENT_DATE)
  )
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title, cat = EXCLUDED.cat,
    deadline = EXCLUDED.deadline, note = EXCLUDED.note, done = EXCLUDED.done;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_goal(text, text, jsonb) TO anon;

-- Quiz upsert
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_quiz(
  p_teacher_pin text, p_quiz jsonb, p_questions jsonb, p_assignee_ids jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_q jsonb; v_i integer := 0; v_sid text;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.quizzes (id, title, subject, description, time_limit, pass_percent, deadline, created_at)
  VALUES (
    p_quiz->>'id', p_quiz->>'title', COALESCE(p_quiz->>'subject', ''),
    COALESCE(p_quiz->>'description', ''), COALESCE((p_quiz->>'time_limit')::integer, 30),
    COALESCE((p_quiz->>'pass_percent')::integer, 60),
    NULLIF(p_quiz->>'deadline', '')::date,
    COALESCE(NULLIF(p_quiz->>'created_at','')::date, CURRENT_DATE)
  )
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title, subject = EXCLUDED.subject,
    description = EXCLUDED.description, time_limit = EXCLUDED.time_limit,
    pass_percent = EXCLUDED.pass_percent, deadline = EXCLUDED.deadline;

  DELETE FROM public.quiz_questions WHERE quiz_id = p_quiz->>'id';
  FOR v_q IN SELECT * FROM jsonb_array_elements(p_questions) LOOP
    INSERT INTO public.quiz_questions (id, quiz_id, sort_order, type, text, options, correct_answer, marks, upload_instructions)
    VALUES (
      v_q->>'id', p_quiz->>'id', v_i,
      v_q->>'type', v_q->>'text',
      COALESCE((v_q->'options')::jsonb, '[]'::jsonb),
      v_q->>'correct_answer', COALESCE((v_q->>'marks')::integer, 1),
      v_q->>'upload_instructions'
    );
    v_i := v_i + 1;
  END LOOP;

  DELETE FROM public.quiz_assignees WHERE quiz_id = p_quiz->>'id';
  FOR v_sid IN SELECT jsonb_array_elements_text(p_assignee_ids) LOOP
    INSERT INTO public.quiz_assignees (quiz_id, student_id) VALUES (p_quiz->>'id', v_sid)
    ON CONFLICT DO NOTHING;
  END LOOP;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_quiz(text, jsonb, jsonb, jsonb) TO anon;

-- Quiz submission
CREATE OR REPLACE FUNCTION public.madrasa_rel_submit_quiz(
  p_student_pin text, p_student_id text, p_submission jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.students WHERE id = p_student_id AND pin = p_student_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;
  INSERT INTO public.quiz_submissions (id, quiz_id, student_id, student_name, answers, score, total, passed, needs_manual_grade, submitted_at)
  VALUES (
    p_submission->>'id', p_submission->>'quiz_id', p_student_id,
    COALESCE(p_submission->>'student_name', ''),
    COALESCE((p_submission->'answers')::jsonb, '{}'::jsonb),
    COALESCE((p_submission->>'score')::integer, 0),
    COALESCE((p_submission->>'total')::integer, 0),
    COALESCE((p_submission->>'passed')::boolean, false),
    COALESCE((p_submission->>'needs_manual_grade')::boolean, false),
    COALESCE((p_submission->>'submitted_at')::timestamptz, now())
  )
  ON CONFLICT (quiz_id, student_id) DO UPDATE SET
    answers = EXCLUDED.answers, score = EXCLUDED.score,
    total = EXCLUDED.total, passed = EXCLUDED.passed,
    needs_manual_grade = EXCLUDED.needs_manual_grade, submitted_at = EXCLUDED.submitted_at;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_submit_quiz(text, text, jsonb) TO anon;

-- Document insert
CREATE OR REPLACE FUNCTION public.madrasa_rel_insert_document(
  p_pin text, p_role text, p_doc jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (SELECT 1 FROM public.students WHERE id = (p_doc->>'student_id') AND pin = p_pin);
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.documents (id, student_id, student_name, file_name, file_type, file_size, category, note, storage_path, file_url, is_read, uploaded_at)
  VALUES (
    p_doc->>'id', p_doc->>'student_id', COALESCE(p_doc->>'student_name', ''),
    p_doc->>'file_name', COALESCE(p_doc->>'file_type', ''),
    COALESCE((p_doc->>'file_size')::bigint, 0),
    COALESCE(p_doc->>'category', 'general'), COALESCE(p_doc->>'note', ''),
    p_doc->>'storage_path', p_doc->>'file_url',
    COALESCE((p_doc->>'is_read')::boolean, false),
    COALESCE((p_doc->>'uploaded_at')::timestamptz, now())
  )
  ON CONFLICT (id) DO UPDATE SET
    file_url = EXCLUDED.file_url, is_read = EXCLUDED.is_read;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_insert_document(text, text, jsonb) TO anon;

-- Teacher PIN update
CREATE OR REPLACE FUNCTION public.madrasa_rel_update_teacher_pin(
  p_old_pin text, p_new_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_old_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  UPDATE public.madrasa_config SET teacher_pin = p_new_pin, updated_at = now() WHERE id = 'singleton';
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_update_teacher_pin(text, text) TO anon;

-- PWA subscription save
CREATE OR REPLACE FUNCTION public.madrasa_rel_save_pwa_subscription(
  p_id text, p_role text, p_subscription jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.pwa_subscriptions (id, role, subscription, updated_at)
  VALUES (p_id, p_role, p_subscription, now())
  ON CONFLICT (id) DO UPDATE SET subscription = EXCLUDED.subscription, updated_at = now();
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_save_pwa_subscription(text, text, jsonb) TO anon;;
