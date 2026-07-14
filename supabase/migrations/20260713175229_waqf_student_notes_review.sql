-- বিবরণ (student notes) রিভিউ ওয়ার্কফ্লো — waqf_documents.review_status প্যাটার্নের অনুরূপ।
-- Scope guard: this migration may reference only public.waqf_* data tables.

ALTER TABLE public.waqf_student_notes
  ADD COLUMN IF NOT EXISTS review_status TEXT NOT NULL DEFAULT 'done';

CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_student_note(
  p_pin TEXT,
  p_student_id TEXT,
  p_note JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ok BOOLEAN;
  v_existing_status TEXT;
  v_status TEXT;
BEGIN
  v_ok := EXISTS (
    SELECT 1 FROM public.waqf_students
    WHERE id = p_student_id AND pin = p_pin
  );
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  SELECT review_status INTO v_existing_status
  FROM public.waqf_student_notes
  WHERE id = p_note->>'id';

  IF v_existing_status = 'done' THEN
    RAISE EXCEPTION 'note_locked';
  END IF;

  INSERT INTO public.waqf_student_notes (
    id, student_id, category_id, note_date, note_time, title, text, review_status
  ) VALUES (
    p_note->>'id',
    p_student_id,
    COALESCE(NULLIF(btrim(p_note->>'category_id'), ''), 'general'),
    COALESCE(p_note->>'date', ''),
    COALESCE(p_note->>'time', ''),
    COALESCE(p_note->>'title', ''),
    COALESCE(p_note->>'text', ''),
    'pending'
  )
  ON CONFLICT (id) DO UPDATE SET
    category_id = EXCLUDED.category_id,
    note_date   = EXCLUDED.note_date,
    note_time   = EXCLUDED.note_time,
    title       = EXCLUDED.title,
    text        = EXCLUDED.text
  RETURNING review_status INTO v_status;

  RETURN jsonb_build_object('ok', true, 'review_status', v_status);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_student_note(TEXT, TEXT, JSONB) TO anon;

CREATE OR REPLACE FUNCTION public.madrasa_rel_delete_student_note(
  p_pin TEXT,
  p_student_id TEXT,
  p_note_id TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ok BOOLEAN;
  v_status TEXT;
BEGIN
  v_ok := EXISTS (
    SELECT 1 FROM public.waqf_students
    WHERE id = p_student_id AND pin = p_pin
  );
  IF NOT v_ok THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  SELECT review_status INTO v_status
  FROM public.waqf_student_notes
  WHERE id = p_note_id AND student_id = p_student_id;

  IF v_status = 'done' THEN
    RAISE EXCEPTION 'note_locked';
  END IF;

  DELETE FROM public.waqf_student_notes
  WHERE id = p_note_id AND student_id = p_student_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_delete_student_note(TEXT, TEXT, TEXT) TO anon;

-- শিক্ষক: এই বিবরণ পর্যালোচনা সম্পন্ন — এরপর ছাত্র আর এডিট/ডিলিট করতে পারবে না
CREATE OR REPLACE FUNCTION public.madrasa_rel_mark_note_reviewed(
  p_teacher_pin TEXT,
  p_note_id TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN RAISE EXCEPTION 'invalid_pin'; END IF;

  UPDATE public.waqf_student_notes
  SET review_status = 'done'
  WHERE id = p_note_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_mark_note_reviewed(TEXT, TEXT) TO anon;

REVOKE ALL ON FUNCTION public.madrasa_rel_upsert_student_note(TEXT, TEXT, JSONB) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.madrasa_rel_delete_student_note(TEXT, TEXT, TEXT) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.madrasa_rel_mark_note_reviewed(TEXT, TEXT) FROM PUBLIC, authenticated;
;
