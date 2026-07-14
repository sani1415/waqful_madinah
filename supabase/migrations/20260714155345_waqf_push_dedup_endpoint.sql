-- Keep a browser push endpoint assigned to one current notification slot.
-- Without this, the same Chrome/PWA endpoint can remain saved under both
-- teacher and student rows, so one physical device receives both directions.

CREATE OR REPLACE FUNCTION public.madrasa_rel_save_pwa_subscription(
  p_id text, p_role text, p_subscription jsonb, p_pin text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ok boolean := false;
  v_endpoint text := NULLIF(p_subscription->>'endpoint', '');
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

  IF v_endpoint IS NOT NULL THEN
    DELETE FROM public.waqf_pwa_subscriptions
    WHERE id <> p_id
      AND subscription->>'endpoint' = v_endpoint;
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

REVOKE ALL ON FUNCTION public.madrasa_rel_save_pwa_subscription(text, text, jsonb, text)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_save_pwa_subscription(text, text, jsonb, text)
  TO anon;
