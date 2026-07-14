-- Oral exam audio support for the waqf app.
-- Audio bytes are stored in the existing private `waqf-files` Storage bucket
-- under oral-exams/...; quiz submissions keep only lightweight metadata in
-- answers jsonb.

ALTER TABLE public.waqf_quizzes
  ADD COLUMN IF NOT EXISTS audio_limit_seconds integer NOT NULL DEFAULT 120;
DO $$
BEGIN
  ALTER TABLE public.waqf_quizzes
    ADD CONSTRAINT waqf_quizzes_audio_limit_seconds_chk
    CHECK (audio_limit_seconds BETWEEN 15 AND 600);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
CREATE OR REPLACE FUNCTION public.madrasa_rel_upsert_quiz(
  p_teacher_pin text, p_quiz jsonb, p_questions jsonb, p_assignee_ids jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_q jsonb;
  v_i integer := 0;
  v_sid text;
  v_audio_limit integer;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;

  v_audio_limit := LEAST(
    600,
    GREATEST(15, COALESCE(NULLIF(p_quiz->>'audio_limit_seconds', '')::integer, 120))
  );

  INSERT INTO public.waqf_quizzes (
    id, title, subject, description, time_limit, audio_limit_seconds,
    pass_percent, deadline, created_at
  )
  VALUES (
    p_quiz->>'id',
    p_quiz->>'title',
    COALESCE(p_quiz->>'subject', ''),
    COALESCE(p_quiz->>'description', ''),
    COALESCE((p_quiz->>'time_limit')::integer, 30),
    v_audio_limit,
    COALESCE((p_quiz->>'pass_percent')::integer, 60),
    NULLIF(p_quiz->>'deadline', '')::date,
    COALESCE(NULLIF(p_quiz->>'created_at','')::date, CURRENT_DATE)
  )
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title,
    subject = EXCLUDED.subject,
    description = EXCLUDED.description,
    time_limit = EXCLUDED.time_limit,
    audio_limit_seconds = EXCLUDED.audio_limit_seconds,
    pass_percent = EXCLUDED.pass_percent,
    deadline = EXCLUDED.deadline;

  DELETE FROM public.waqf_quiz_questions WHERE quiz_id = p_quiz->>'id';
  FOR v_q IN SELECT * FROM jsonb_array_elements(p_questions) LOOP
    INSERT INTO public.waqf_quiz_questions (
      id, quiz_id, sort_order, type, text, options, correct_answer, marks,
      upload_instructions
    )
    VALUES (
      v_q->>'id',
      p_quiz->>'id',
      v_i,
      v_q->>'type',
      v_q->>'text',
      COALESCE((v_q->'options')::jsonb, '[]'::jsonb),
      v_q->>'correct_answer',
      COALESCE((v_q->>'marks')::integer, 1),
      v_q->>'upload_instructions'
    );
    v_i := v_i + 1;
  END LOOP;

  DELETE FROM public.waqf_quiz_assignees WHERE quiz_id = p_quiz->>'id';
  FOR v_sid IN SELECT jsonb_array_elements_text(p_assignee_ids) LOOP
    INSERT INTO public.waqf_quiz_assignees (quiz_id, student_id)
    VALUES (p_quiz->>'id', v_sid)
    ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION public.madrasa_rel_upsert_quiz(text, jsonb, jsonb, jsonb)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_upsert_quiz(text, jsonb, jsonb, jsonb)
  TO anon;
