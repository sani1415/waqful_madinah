-- Persist teacher document-review feedback and notify the student atomically.

ALTER TABLE public.waqf_documents
  ADD COLUMN IF NOT EXISTS review_comment text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS review_message_id text;

CREATE OR REPLACE FUNCTION public.madrasa_rel_review_document(
  p_teacher_pin text,
  p_doc_id text,
  p_comment text,
  p_message_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc public.waqf_documents%ROWTYPE;
  v_comment text := trim(COALESCE(p_comment, ''));
  v_reviewed_at timestamptz := now();
  v_message_text text;
BEGIN
  IF NOT private.verify_teacher_pin(p_teacher_pin) THEN
    RAISE EXCEPTION 'invalid_pin';
  END IF;

  SELECT * INTO v_doc
  FROM public.waqf_documents
  WHERE id = p_doc_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'document_not_found'; END IF;

  IF v_doc.review_status = 'done' AND v_doc.reviewed_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_reviewed', true,
      'review_comment', v_doc.review_comment,
      'reviewed_at', v_doc.reviewed_at,
      'message_id', v_doc.review_message_id
    );
  END IF;

  v_message_text := 'আপনার “' || COALESCE(v_doc.file_name, 'ডকুমেন্ট') || '” ডকুমেন্টটি পর্যালোচনা করা হয়েছে।';
  IF v_comment <> '' THEN
    v_message_text := v_message_text || ' · মন্তব্য: ' || v_comment;
  END IF;

  UPDATE public.waqf_documents
  SET review_status = 'done',
      is_read = true,
      review_comment = v_comment,
      reviewed_at = v_reviewed_at,
      review_message_id = p_message_id
  WHERE id = p_doc_id;

  INSERT INTO public.waqf_messages (
    id, thread_id, role, type, text, extra, is_read, sent_at
  ) VALUES (
    p_message_id,
    v_doc.student_id,
    'out',
    'text',
    v_message_text,
    jsonb_build_object(
      'docId', v_doc.id,
      'fileName', v_doc.file_name,
      'reviewComment', v_comment,
      'reviewedAt', v_reviewed_at
    ),
    false,
    v_reviewed_at
  );

  RETURN jsonb_build_object(
    'ok', true,
    'review_comment', v_comment,
    'reviewed_at', v_reviewed_at,
    'message_id', p_message_id,
    'message_text', v_message_text
  );
END;
$$;

REVOKE ALL ON FUNCTION public.madrasa_rel_review_document(text, text, text, text)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.madrasa_rel_review_document(text, text, text, text)
  TO anon;
