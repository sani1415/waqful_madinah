CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_message(
  p_teacher_pin text,
  p_message_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;
  IF p_message_id IS NULL OR trim(p_message_id) = '' THEN
    RAISE EXCEPTION 'invalid_message_id';
  END IF;

  DELETE FROM public.messages WHERE id = p_message_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_message(text, text) TO anon;;
