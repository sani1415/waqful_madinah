CREATE OR REPLACE FUNCTION hub_dept_summary(
  p_user_id uuid,
  p_pin     text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user shared_users;
BEGIN
  SELECT * INTO v_user FROM shared_users
  WHERE id = p_user_id AND pin = p_pin AND role = 'admin' AND is_active = true LIMIT 1;
  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'অনুমতি নেই');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'total_depts',   (SELECT COUNT(*) FROM dept_departments WHERE is_active = true),
    'total_income',  (SELECT COALESCE(SUM(amount),0) FROM dept_transactions WHERE type='income'),
    'total_expense', (SELECT COALESCE(SUM(amount),0) FROM dept_transactions WHERE type='expense'),
    'departments', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'name',    sub.dname,
          'emoji',   sub.demoji,
          'income',  sub.income,
          'expense', sub.expense
        )
        ORDER BY sub.sort_order
      )
      FROM (
        SELECT d.name AS dname, d.emoji AS demoji, d.sort_order,
               COALESCE(SUM(t.amount) FILTER (WHERE t.type='income'),  0) AS income,
               COALESCE(SUM(t.amount) FILTER (WHERE t.type='expense'), 0) AS expense
        FROM dept_departments d
        LEFT JOIN dept_transactions t ON t.dept_id = d.id
        WHERE d.is_active = true
        GROUP BY d.id, d.name, d.emoji, d.sort_order
      ) sub
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION hub_dept_summary TO anon;;
