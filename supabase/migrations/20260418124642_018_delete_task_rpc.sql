CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_task(
  p_teacher_pin text,
  p_task_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;
  IF p_task_id IS NULL OR trim(p_task_id) = '' THEN
    RAISE EXCEPTION 'invalid_task_id';
  END IF;

  DELETE FROM public.task_assignments WHERE task_id = p_task_id;
  DELETE FROM public.task_completions WHERE task_id = p_task_id;
  DELETE FROM public.tasks WHERE id = p_task_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_task(text, text) TO anon;;
