-- 1-ক · Message insert: enforce ownership
CREATE OR REPLACE FUNCTION public.madrasa_rel_insert_message(
  p_pin text, p_role text, p_message jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_thread     text := p_message->>'thread_id';
  v_role       text;
  v_student_id text;
BEGIN
  IF p_role = 'teacher' THEN
    IF NOT private.verify_teacher_pin(p_pin) THEN
      RAISE EXCEPTION 'invalid_pin';
    END IF;
    v_role := 'out';
    IF v_thread <> '_bc'
       AND NOT EXISTS (SELECT 1 FROM public.waqf_students WHERE id = v_thread) THEN
      RAISE EXCEPTION 'bad_thread';
    END IF;
  ELSIF p_role = 'student' THEN
    SELECT id INTO v_student_id
    FROM public.waqf_students
    WHERE waqf_id = (p_message->>'thread_id_waqf') AND pin = p_pin;
    IF v_student_id IS NULL THEN
      RAISE EXCEPTION 'invalid_pin';
    END IF;
    IF v_thread IS DISTINCT FROM v_student_id THEN
      RAISE EXCEPTION 'forbidden_thread';
    END IF;
    v_role := 'in';
  ELSE
    RAISE EXCEPTION 'bad_role';
  END IF;

  INSERT INTO public.waqf_messages (id, thread_id, role, type, text, extra, is_read, sent_at)
  VALUES (
    p_message->>'id',
    v_thread,
    v_role,
    COALESCE(p_message->>'type', 'text'),
    COALESCE(p_message->>'text', ''),
    COALESCE((p_message->'extra')::jsonb, '{}'::jsonb),
    COALESCE((p_message->>'is_read')::boolean, false),
    COALESCE((p_message->>'sent_at')::timestamptz, now())
  );
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.madrasa_rel_insert_message(text, text, jsonb) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_insert_message(text, text, jsonb) TO anon;

-- 1-খ · Storage: remove unused anon DELETE + UPDATE policies
DROP POLICY IF EXISTS "waqf_files_delete" ON storage.objects;
DROP POLICY IF EXISTS "waqf_files_update" ON storage.objects;

-- 1-গ · PWA subscription: PIN-gate teacher + personal-student slots
DROP FUNCTION IF EXISTS public.madrasa_rel_save_pwa_subscription(text, text, jsonb);

CREATE OR REPLACE FUNCTION public.madrasa_rel_save_pwa_subscription(
  p_id text, p_role text, p_subscription jsonb, p_pin text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_ok boolean := false;
BEGIN
  IF p_id = 'teacher' OR p_role = 'teacher' THEN
    v_ok := private.verify_teacher_pin(p_pin);
  ELSIF p_id LIKE 'shared_device_%' THEN
    v_ok := true;
  ELSE
    v_ok := EXISTS (
      SELECT 1 FROM public.waqf_students WHERE waqf_id = p_id AND pin = p_pin
    );
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;

  INSERT INTO public.waqf_pwa_subscriptions (id, role, subscription, updated_at)
  VALUES (p_id, p_role, p_subscription, now())
  ON CONFLICT (id) DO UPDATE SET
    subscription = EXCLUDED.subscription,
    role = EXCLUDED.role,
    updated_at = now();
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.madrasa_rel_save_pwa_subscription(text, text, jsonb, text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_save_pwa_subscription(text, text, jsonb, text) TO anon;;
