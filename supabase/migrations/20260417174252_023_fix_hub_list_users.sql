CREATE OR REPLACE FUNCTION hub_rel_list_users(p_user_id uuid, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user shared_users;
BEGIN
  SELECT * INTO v_user FROM shared_users
  WHERE id = p_user_id AND pin = p_pin AND role = 'admin' AND is_active = true LIMIT 1;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'অনুমতি নেই'); END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'data', (
      SELECT jsonb_agg(row_to_json(r) ORDER BY r.created_at) FROM (
        SELECT u.id, u.name, u.role, u.module_access, u.is_active, u.created_at,
               d.name AS dept_name, c.name AS class_name
        FROM shared_users u
        LEFT JOIN dept_departments d ON d.id = u.dept_id
        LEFT JOIN mdr_classes c ON c.id = u.class_id
        WHERE u.role != 'admin'
      ) r
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION hub_rel_list_users TO anon;;
