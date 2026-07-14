CREATE OR REPLACE FUNCTION public.madrasa_rel_clear_student_data(
  p_teacher_pin text,
  p_student_id  text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  DELETE FROM public.messages         WHERE thread_id  = p_student_id;
  DELETE FROM public.goals            WHERE student_id = p_student_id;
  DELETE FROM public.task_assignments WHERE student_id = p_student_id;
  DELETE FROM public.quiz_submissions WHERE student_id = p_student_id;
  DELETE FROM public.quiz_assignees   WHERE student_id = p_student_id;
  DELETE FROM public.documents        WHERE student_id = p_student_id;
  DELETE FROM public.academic_history WHERE student_id = p_student_id;
  DELETE FROM public.teacher_notes    WHERE student_id = p_student_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_clear_student_data(text, text) TO anon;;
