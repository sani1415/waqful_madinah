-- Remove 11-markaz (Markaz hub) database objects; leaves other app tables untouched.

-- 1) Drop public RPCs (narrow patterns so unrelated functions are not touched)
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN (
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (
        p.proname LIKE 'dept_rel_%'
        OR p.proname LIKE 'mdr_rel_%'
        OR p.proname LIKE 'kh_rel_%'
        OR p.proname LIKE 'hub_rel_%'
        OR p.proname IN ('hub_mdr_summary', 'hub_dept_summary', 'hub_kh_summary')
      )
  ) LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.fn::text || ' CASCADE';
  END LOOP;
END $$;

-- 2) Drop private helpers used only by this app
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN (
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
        'get_mdr_user', 'get_kh_user', 'verify_admin_pin', 'verify_user_pin', 'set_updated_at'
      )
  ) LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.fn::text || ' CASCADE';
  END LOOP;
END $$;

-- 3) Drop all 32 application tables (CASCADE handles FK order)
DROP TABLE IF EXISTS
  kh_fund_transactions,
  kh_logs,
  kh_activities,
  kh_beneficiaries,
  kh_activity_types,
  mdr_alumni_followups,
  mdr_alumni,
  mdr_library_issues,
  mdr_library_books,
  mdr_hifz_progress,
  mdr_hifz_students,
  mdr_hifz_groups,
  mdr_logs,
  mdr_fee_summary,
  mdr_exam_results,
  mdr_exam_subjects,
  mdr_exams,
  mdr_akhlaq,
  mdr_book_progress,
  mdr_books,
  mdr_attendance_details,
  mdr_attendance,
  mdr_class_history,
  mdr_students,
  mdr_classes,
  mdr_divisions,
  dept_edit_requests,
  dept_transactions,
  dept_inventory,
  dept_departments,
  shared_users
CASCADE;
;
