-- Teacher-defined contact groups (tag/category system for quick messaging)

CREATE TABLE IF NOT EXISTS public.student_groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  student_ids JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.student_groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "deny_all_direct" ON public.student_groups FOR ALL USING (false);

-- Upsert a group (create or update name/members)
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_group(
  p_teacher_pin TEXT,
  p_id TEXT,
  p_name TEXT,
  p_student_ids JSONB
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  INSERT INTO public.student_groups (id, name, student_ids, updated_at)
  VALUES (p_id, p_name, COALESCE(p_student_ids, '[]'::JSONB), NOW())
  ON CONFLICT (id) DO UPDATE
    SET name        = EXCLUDED.name,
        student_ids = EXCLUDED.student_ids,
        updated_at  = NOW();
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_group(TEXT, TEXT, TEXT, JSONB) TO anon;

-- Delete a group
CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_group(
  p_teacher_pin TEXT,
  p_group_id TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  DELETE FROM public.student_groups WHERE id = p_group_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_group(TEXT, TEXT) TO anon;

-- Get all groups for the teacher
CREATE OR REPLACE FUNCTION public.madrasa_rel_get_groups(
  p_teacher_pin TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',          id,
        'name',        name,
        'student_ids', student_ids,
        'created_at',  created_at
      ) ORDER BY created_at
    ),
    '[]'::JSONB
  ) INTO v_result
  FROM public.student_groups;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_get_groups(TEXT) TO anon;;
