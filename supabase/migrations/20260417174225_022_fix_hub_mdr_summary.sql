CREATE OR REPLACE FUNCTION hub_mdr_summary(p_user_id uuid, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user shared_users;
BEGIN
  SELECT * INTO v_user FROM shared_users
  WHERE id = p_user_id AND pin = p_pin AND role = 'admin' AND is_active = true LIMIT 1;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'অনুমতি নেই'); END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'total_students',  (SELECT COUNT(*) FROM mdr_students WHERE status='active'),
    'kitab_students',  (SELECT COUNT(*) FROM mdr_students st JOIN mdr_divisions d ON d.id=st.division_id WHERE st.status='active' AND d.code='kitab'),
    'maktab_students', (SELECT COUNT(*) FROM mdr_students st JOIN mdr_divisions d ON d.id=st.division_id WHERE st.status='active' AND d.code='maktab'),
    'hifz_students',   (SELECT COUNT(*) FROM mdr_students WHERE status='active' AND is_hifz=true),
    'today_attendance', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'class',   sub.class_name,
          'present', sub.present_count,
          'absent',  sub.absent_count
        )
      )
      FROM (
        SELECT c.name AS class_name,
               COUNT(ad.id) FILTER (WHERE ad.is_present = true)  AS present_count,
               COUNT(ad.id) FILTER (WHERE ad.is_present = false) AS absent_count
        FROM mdr_attendance a
        JOIN mdr_classes c  ON c.id = a.class_id
        JOIN mdr_attendance_details ad ON ad.attendance_id = a.id
        WHERE a.date = CURRENT_DATE
        GROUP BY c.name
      ) sub
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION hub_mdr_summary TO anon;;
