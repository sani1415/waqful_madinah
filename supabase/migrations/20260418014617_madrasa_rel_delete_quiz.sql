CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_quiz(
  p_teacher_pin text,
  p_quiz_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;
  IF p_quiz_id IS NULL OR trim(p_quiz_id) = '' THEN
    RAISE EXCEPTION 'invalid_quiz_id';
  END IF;

  DELETE FROM public.quizzes WHERE id = p_quiz_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_quiz(text, text) TO anon;;
