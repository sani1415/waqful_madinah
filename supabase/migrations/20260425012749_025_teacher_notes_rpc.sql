
-- Upsert a single teacher note
CREATE OR REPLACE FUNCTION madrasa_rel_upsert_teacher_note(
  p_teacher_pin text,
  p_id          text,
  p_student_id  text,
  p_text        text,
  p_date        text DEFAULT NULL,
  p_time        text DEFAULT '',
  p_edited_at   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_note_date date;
  v_edited    date;
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  v_note_date := CASE WHEN p_date IS NOT NULL AND p_date <> '' THEN p_date::date ELSE CURRENT_DATE END;
  v_edited    := CASE WHEN p_edited_at IS NOT NULL AND p_edited_at <> '' THEN p_edited_at::date ELSE NULL END;
  INSERT INTO public.teacher_notes(id, student_id, text, note_date, note_time, edited_at)
  VALUES (p_id, p_student_id, p_text, v_note_date, COALESCE(p_time,''), v_edited)
  ON CONFLICT (id) DO UPDATE SET
    text       = EXCLUDED.text,
    note_date  = EXCLUDED.note_date,
    note_time  = EXCLUDED.note_time,
    edited_at  = EXCLUDED.edited_at;
END;
$$;
GRANT EXECUTE ON FUNCTION madrasa_rel_upsert_teacher_note TO anon;

-- Delete a single teacher note
CREATE OR REPLACE FUNCTION madrasa_rel_delete_teacher_note(
  p_teacher_pin text,
  p_id          text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM private.verify_teacher_pin(p_teacher_pin);
  DELETE FROM public.teacher_notes WHERE id = p_id;
END;
$$;
GRANT EXECUTE ON FUNCTION madrasa_rel_delete_teacher_note TO anon;
;
