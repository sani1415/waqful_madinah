
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_completion(
  p_pin        text,
  p_role       text,
  p_id         text,
  p_task_id    text,
  p_student_id text,
  p_date       date,
  p_status     text,
  p_completed_at timestamptz,
  p_note       text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (
      SELECT 1 FROM public.students
      WHERE id = p_student_id AND pin = p_pin
    );
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.task_completions
    (id, task_id, student_id, date, status, completed_at, note)
  VALUES
    (p_id, p_task_id, p_student_id, p_date, p_status, p_completed_at, COALESCE(p_note, ''))
  ON CONFLICT (task_id, student_id, date) DO UPDATE SET
    status       = EXCLUDED.status,
    completed_at = EXCLUDED.completed_at,
    note         = EXCLUDED.note;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_completion(text,text,text,text,text,date,text,timestamptz,text) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_completion(
  p_pin        text,
  p_role       text,
  p_task_id    text,
  p_student_id text,
  p_date       date
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (
      SELECT 1 FROM public.students
      WHERE id = p_student_id AND pin = p_pin
    );
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  DELETE FROM public.task_completions
  WHERE task_id = p_task_id
    AND student_id = p_student_id
    AND date = p_date;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_completion(text,text,text,text,date) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_student_completions(
  p_pin        text,
  p_role       text,
  p_student_id text,
  p_from       date,
  p_to         date
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSE
    v_ok := EXISTS (
      SELECT 1 FROM public.students
      WHERE id = p_student_id AND pin = p_pin
    );
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  RETURN (
    SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM (
      SELECT * FROM public.task_completions
      WHERE student_id = p_student_id
        AND date BETWEEN p_from AND p_to
      ORDER BY date DESC
    ) t
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_student_completions(text,text,text,date,date) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_daily_completions(
  p_teacher_pin text,
  p_date        date
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;

  RETURN (
    SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM (
      SELECT * FROM public.task_completions
      WHERE date = p_date
      ORDER BY student_id, task_id
    ) t
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_daily_completions(text,date) TO anon;
;
