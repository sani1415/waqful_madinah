-- Text messages: edit / delete within 15 minutes (WhatsApp-style), own messages only.

CREATE OR REPLACE FUNCTION public.madrasa_rel_update_message_text(
  p_pin text,
  p_role text,
  p_message_id text,
  p_new_text text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_msg public.messages%ROWTYPE;
  v_trim text := trim(coalesce(p_new_text, ''));
BEGIN
  IF p_message_id IS NULL OR trim(p_message_id) = '' THEN
    RAISE EXCEPTION 'invalid_message_id';
  END IF;
  IF length(v_trim) = 0 THEN
    RAISE EXCEPTION 'empty_text';
  END IF;
  IF length(v_trim) > 8000 THEN
    v_trim := left(v_trim, 8000);
  END IF;

  SELECT * INTO v_msg FROM public.messages WHERE id = p_message_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
  IF v_msg.type IS DISTINCT FROM 'text' THEN
    RAISE EXCEPTION 'not_text';
  END IF;
  IF (now() - v_msg.sent_at) > interval '15 minutes' THEN
    RAISE EXCEPTION 'expired';
  END IF;

  IF p_role = 'teacher' THEN
    IF NOT private.verify_teacher_pin(p_pin) THEN
      RAISE EXCEPTION 'invalid_pin';
    END IF;
    IF v_msg.role IS DISTINCT FROM 'out' THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
    IF v_msg.thread_id = '_bc' THEN
      NULL;
    ELSIF NOT EXISTS (SELECT 1 FROM public.students s WHERE s.id = v_msg.thread_id) THEN
      RAISE EXCEPTION 'bad_thread';
    END IF;
  ELSIF p_role = 'student' THEN
    IF v_msg.role IS DISTINCT FROM 'in' OR v_msg.thread_id = '_bc' THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.students s
      WHERE s.id = v_msg.thread_id AND s.pin = p_pin
    ) THEN
      RAISE EXCEPTION 'invalid_pin';
    END IF;
  ELSE
    RAISE EXCEPTION 'bad_role';
  END IF;

  UPDATE public.messages
  SET text = v_trim,
      extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('editedAt', to_jsonb(now()::text))
  WHERE id = p_message_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.madrasa_rel_update_message_text(text, text, text, text) TO anon;


CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_own_message(
  p_pin text,
  p_role text,
  p_message_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_msg public.messages%ROWTYPE;
BEGIN
  IF p_message_id IS NULL OR trim(p_message_id) = '' THEN
    RAISE EXCEPTION 'invalid_message_id';
  END IF;

  SELECT * INTO v_msg FROM public.messages WHERE id = p_message_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
  IF v_msg.type IS DISTINCT FROM 'text' THEN
    RAISE EXCEPTION 'not_text';
  END IF;
  IF (now() - v_msg.sent_at) > interval '15 minutes' THEN
    RAISE EXCEPTION 'expired';
  END IF;

  IF p_role = 'teacher' THEN
    IF NOT private.verify_teacher_pin(p_pin) THEN
      RAISE EXCEPTION 'invalid_pin';
    END IF;
    IF v_msg.role IS DISTINCT FROM 'out' THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
    IF v_msg.thread_id = '_bc' THEN
      NULL;
    ELSIF NOT EXISTS (SELECT 1 FROM public.students s WHERE s.id = v_msg.thread_id) THEN
      RAISE EXCEPTION 'bad_thread';
    END IF;
  ELSIF p_role = 'student' THEN
    IF v_msg.role IS DISTINCT FROM 'in' OR v_msg.thread_id = '_bc' THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.students s
      WHERE s.id = v_msg.thread_id AND s.pin = p_pin
    ) THEN
      RAISE EXCEPTION 'invalid_pin';
    END IF;
  ELSE
    RAISE EXCEPTION 'bad_role';
  END IF;

  DELETE FROM public.messages WHERE id = p_message_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_own_message(text, text, text) TO anon;;
