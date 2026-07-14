DO $$
DECLARE
  v_core jsonb;
  v_goals jsonb;
  v_exams jsonb;
  v_docs jsonb;
  v_academic jsonb;
  v_tnotes jsonb;
  v_teacher_pin jsonb;
  v_student jsonb;
  v_msg jsonb;
  v_task jsonb;
  v_goal jsonb;
  v_quiz jsonb;
  v_question jsonb;
  v_submission jsonb;
  v_doc jsonb;
  v_sid text;
  v_i integer;
BEGIN
  SELECT value INTO v_core FROM public.app_kv WHERE key = 'core';
  SELECT value INTO v_goals FROM public.app_kv WHERE key = 'goals';
  SELECT value INTO v_exams FROM public.app_kv WHERE key = 'exams';
  SELECT value INTO v_docs FROM public.app_kv WHERE key = 'docs_meta';
  SELECT value INTO v_academic FROM public.app_kv WHERE key = 'academic';
  SELECT value INTO v_tnotes FROM public.app_kv WHERE key = 'tnotes';
  SELECT value INTO v_teacher_pin FROM public.app_kv WHERE key = 'teacher_pin';

  IF v_core IS NULL THEN
    RAISE NOTICE 'app_kv "core" নেই — migration skip';
    RETURN;
  END IF;

  INSERT INTO public.madrasa_config (id, teacher_name, madrasa_name, teacher_pin)
  VALUES (
    'singleton',
    COALESCE(v_core->'teacher'->>'name', ''),
    COALESCE(v_core->'teacher'->>'madrasa', 'Waqful Madinah'),
    COALESCE(v_teacher_pin->>'pin', '1234')
  )
  ON CONFLICT (id) DO UPDATE SET
    teacher_name = EXCLUDED.teacher_name,
    madrasa_name = EXCLUDED.madrasa_name,
    teacher_pin = EXCLUDED.teacher_pin;

  FOR v_student IN SELECT * FROM jsonb_array_elements(COALESCE(v_core->'students', '[]')) LOOP
    INSERT INTO public.students (id, waqf_id, name, cls, roll, pin, color, note,
      father_name, father_occupation, contact, district, upazila, blood_group, enrollment_date)
    VALUES (
      v_student->>'id', v_student->>'waqfId', v_student->>'name',
      COALESCE(v_student->>'cls', ''), COALESCE(v_student->>'roll', ''),
      v_student->>'pin', COALESCE(v_student->>'color', '#128C7E'),
      COALESCE(v_student->>'note', ''), COALESCE(v_student->>'fatherName', ''),
      COALESCE(v_student->>'fatherOccupation', ''), COALESCE(v_student->>'contact', ''),
      COALESCE(v_student->>'district', ''), COALESCE(v_student->>'upazila', ''),
      COALESCE(v_student->>'bloodGroup', ''),
      NULLIF(v_student->>'enrollmentDate', '')::date
    )
    ON CONFLICT (id) DO NOTHING;
  END LOOP;

  FOR v_sid IN SELECT jsonb_object_keys(COALESCE(v_core->'chats', '{}')) LOOP
    FOR v_msg IN SELECT * FROM jsonb_array_elements(COALESCE((v_core->'chats')->v_sid, '[]')) LOOP
      INSERT INTO public.messages (id, thread_id, role, type, text, extra, is_read, sent_at)
      VALUES (
        v_msg->>'id', v_sid,
        COALESCE(v_msg->>'role', 'out'),
        COALESCE(v_msg->>'type', 'text'),
        COALESCE(v_msg->>'text', ''),
        (v_msg - 'id' - 'role' - 'type' - 'text' - 'read' - 'time'),
        COALESCE((v_msg->>'read')::boolean, false),
        now()
      )
      ON CONFLICT (id) DO NOTHING;
    END LOOP;
  END LOOP;

  FOR v_task IN SELECT * FROM jsonb_array_elements(COALESCE(v_core->'tasks', '[]')) LOOP
    INSERT INTO public.tasks (id, title, description, type, deadline, created_at)
    VALUES (
      v_task->>'id', v_task->>'title', COALESCE(v_task->>'desc', ''),
      COALESCE(v_task->>'type', 'onetime'),
      NULLIF(v_task->>'deadline', '')::date,
      COALESCE(NULLIF(v_task->>'created','')::date, CURRENT_DATE)
    )
    ON CONFLICT (id) DO NOTHING;

    FOR v_sid IN SELECT jsonb_object_keys(COALESCE(v_task->'assignees', '{}')) LOOP
      INSERT INTO public.task_assignments (id, task_id, student_id, status, completed_date, completed_time)
      VALUES (
        gen_random_uuid()::text, v_task->>'id', v_sid,
        COALESCE((v_task->'assignees')->>v_sid, 'pending'),
        NULLIF((v_task->'completedBy'->v_sid)->>'date', '')::date,
        (v_task->'completedBy'->v_sid)->>'time'
      )
      ON CONFLICT (task_id, student_id) DO NOTHING;
    END LOOP;
  END LOOP;

  IF v_goals IS NOT NULL THEN
    FOR v_sid IN SELECT jsonb_object_keys(v_goals) LOOP
      FOR v_goal IN SELECT * FROM jsonb_array_elements(COALESCE(v_goals->v_sid, '[]')) LOOP
        INSERT INTO public.goals (id, student_id, title, cat, deadline, note, done, created_at)
        VALUES (
          v_goal->>'id', v_sid, v_goal->>'title',
          COALESCE(v_goal->>'cat', 'other'),
          NULLIF(v_goal->>'deadline', '')::date,
          COALESCE(v_goal->>'note', ''),
          COALESCE((v_goal->>'done')::boolean, false),
          COALESCE(NULLIF(v_goal->>'created','')::date, CURRENT_DATE)
        )
        ON CONFLICT (id) DO NOTHING;
      END LOOP;
    END LOOP;
  END IF;

  IF v_exams IS NOT NULL THEN
    v_i := 0;
    FOR v_quiz IN SELECT * FROM jsonb_array_elements(COALESCE(v_exams->'quizzes', '[]')) LOOP
      INSERT INTO public.quizzes (id, title, subject, description, time_limit, pass_percent, deadline, created_at)
      VALUES (
        v_quiz->>'id', v_quiz->>'title', COALESCE(v_quiz->>'subject', ''),
        COALESCE(v_quiz->>'desc', ''), COALESCE((v_quiz->>'timeLimit')::integer, 30),
        COALESCE((v_quiz->>'passPercent')::integer, 60),
        NULLIF(v_quiz->>'deadline', '')::date,
        COALESCE(NULLIF(v_quiz->>'created','')::date, CURRENT_DATE)
      )
      ON CONFLICT (id) DO NOTHING;

      v_i := 0;
      FOR v_question IN SELECT * FROM jsonb_array_elements(COALESCE(v_quiz->'questions', '[]')) LOOP
        INSERT INTO public.quiz_questions (id, quiz_id, sort_order, type, text, options, correct_answer, marks)
        VALUES (
          v_question->>'id', v_quiz->>'id', v_i,
          v_question->>'type', v_question->>'text',
          COALESCE((v_question->'options')::jsonb, '[]'::jsonb),
          v_question->>'correctAnswer', COALESCE((v_question->>'marks')::integer, 1)
        )
        ON CONFLICT (id) DO NOTHING;
        v_i := v_i + 1;
      END LOOP;

      FOR v_sid IN SELECT jsonb_array_elements_text(COALESCE(v_quiz->'assigneeIds', '[]')) LOOP
        INSERT INTO public.quiz_assignees (quiz_id, student_id) VALUES (v_quiz->>'id', v_sid)
        ON CONFLICT DO NOTHING;
      END LOOP;
    END LOOP;

    FOR v_submission IN SELECT * FROM jsonb_array_elements(COALESCE(v_exams->'submissions', '[]')) LOOP
      INSERT INTO public.quiz_submissions (id, quiz_id, student_id, student_name, answers, score, total, passed, needs_manual_grade)
      VALUES (
        v_submission->>'id', v_submission->>'quizId', v_submission->>'studentId',
        COALESCE(v_submission->>'studentName', ''),
        COALESCE((v_submission->'answers')::jsonb, '{}'::jsonb),
        COALESCE((v_submission->>'score')::integer, 0),
        COALESCE((v_submission->>'total')::integer, 0),
        COALESCE((v_submission->>'passed')::boolean, false),
        COALESCE((v_submission->>'needsManualGrade')::boolean, false)
      )
      ON CONFLICT (quiz_id, student_id) DO NOTHING;
    END LOOP;
  END IF;

  IF v_docs IS NOT NULL THEN
    FOR v_doc IN SELECT * FROM jsonb_array_elements(v_docs) LOOP
      INSERT INTO public.documents (id, student_id, student_name, file_name, file_type, file_size, category, note, storage_path, file_url, is_read)
      VALUES (
        v_doc->>'id', v_doc->>'studentId', COALESCE(v_doc->>'studentName', ''),
        v_doc->>'fileName', COALESCE(v_doc->>'fileType', ''),
        COALESCE((v_doc->>'fileSize')::bigint, 0),
        COALESCE(v_doc->>'category', 'general'), COALESCE(v_doc->>'note', ''),
        v_doc->>'storage_path', v_doc->>'fileUrl',
        COALESCE((v_doc->>'read')::boolean, false)
      )
      ON CONFLICT (id) DO NOTHING;
    END LOOP;
  END IF;

  IF v_academic IS NOT NULL THEN
    FOR v_sid IN SELECT jsonb_object_keys(v_academic) LOOP
      FOR v_doc IN SELECT * FROM jsonb_array_elements(COALESCE(v_academic->v_sid, '[]')) LOOP
        INSERT INTO public.academic_history (id, student_id, year_class, grade, added_at)
        VALUES (
          v_doc->>'id', v_sid, v_doc->>'yearClass', COALESCE(v_doc->>'grade', ''),
          COALESCE(NULLIF(v_doc->>'addedAt','')::date, CURRENT_DATE)
        )
        ON CONFLICT (id) DO NOTHING;
      END LOOP;
    END LOOP;
  END IF;

  IF v_tnotes IS NOT NULL THEN
    FOR v_sid IN SELECT jsonb_object_keys(v_tnotes) LOOP
      FOR v_doc IN SELECT * FROM jsonb_array_elements(COALESCE(v_tnotes->v_sid, '[]')) LOOP
        INSERT INTO public.teacher_notes (id, student_id, text, note_date, note_time)
        VALUES (
          v_doc->>'id', v_sid, v_doc->>'text',
          COALESCE(NULLIF(v_doc->>'date','')::date, CURRENT_DATE),
          COALESCE(v_doc->>'time', '')
        )
        ON CONFLICT (id) DO NOTHING;
      END LOOP;
    END LOOP;
  END IF;

  RAISE NOTICE 'Migration সম্পন্ন।';
END;
$$;;
