-- Add title to student notes (বিবরণ list preview)
ALTER TABLE public.waqf_student_notes
  ADD COLUMN IF NOT EXISTS title TEXT NOT NULL DEFAULT '';

CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_student_note(
  p_pin TEXT,
  p_student_id TEXT,
  p_note JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  v_ok := EXISTS (
    SELECT 1 FROM public.waqf_students
    WHERE id = p_student_id AND pin = p_pin
  );
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  INSERT INTO public.waqf_student_notes (
    id, student_id, category_id, note_date, note_time, title, text
  ) VALUES (
    p_note->>'id',
    p_student_id,
    COALESCE(NULLIF(btrim(p_note->>'category_id'), ''), 'general'),
    COALESCE(p_note->>'date', ''),
    COALESCE(p_note->>'time', ''),
    COALESCE(p_note->>'title', ''),
    COALESCE(p_note->>'text', '')
  )
  ON CONFLICT (id) DO UPDATE SET
    category_id = EXCLUDED.category_id,
    note_date   = EXCLUDED.note_date,
    note_time   = EXCLUDED.note_time,
    title       = EXCLUDED.title,
    text        = EXCLUDED.text;

  RETURN jsonb_build_object('ok', true);
END;
$$;
