-- Fix teacher/student login: batch 3/5 bootstrap used column "date" but table has "comp_date".

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
        WHERE comp_date >= CURRENT_DATE - INTERVAL '35 days'
        ORDER BY comp_date DESC
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
          AND comp_date >= CURRENT_DATE - INTERVAL '35 days'
        ORDER BY comp_date DESC
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
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_bootstrap(text, text) TO anon;;
