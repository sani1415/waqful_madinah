-- Note App (nt_ prefix) — isolated from mdr_* and waqf_* tables

CREATE TABLE IF NOT EXISTS public.nt_folders (
  id uuid PRIMARY KEY,
  owner_key uuid NOT NULL,
  name text NOT NULL CHECK (char_length(trim(name)) > 0),
  color text NOT NULL DEFAULT '#6366f1',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.nt_notes (
  id uuid PRIMARY KEY,
  owner_key uuid NOT NULL,
  folder_id uuid REFERENCES public.nt_folders(id) ON DELETE SET NULL,
  title text NOT NULL DEFAULT '',
  content text NOT NULL DEFAULT '',
  is_pinned boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_nt_folders_owner_key ON public.nt_folders(owner_key);
CREATE INDEX IF NOT EXISTS idx_nt_notes_owner_key ON public.nt_notes(owner_key);
CREATE INDEX IF NOT EXISTS idx_nt_notes_folder_id ON public.nt_notes(folder_id);
CREATE INDEX IF NOT EXISTS idx_nt_notes_updated_at ON public.nt_notes(updated_at DESC);

CREATE OR REPLACE FUNCTION public.nt_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_nt_folders_updated_at ON public.nt_folders;
CREATE TRIGGER trg_nt_folders_updated_at
  BEFORE UPDATE ON public.nt_folders
  FOR EACH ROW EXECUTE FUNCTION public.nt_set_updated_at();

DROP TRIGGER IF EXISTS trg_nt_notes_updated_at ON public.nt_notes;
CREATE TRIGGER trg_nt_notes_updated_at
  BEFORE UPDATE ON public.nt_notes
  FOR EACH ROW EXECUTE FUNCTION public.nt_set_updated_at();

CREATE OR REPLACE FUNCTION public.nt_request_owner_key()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  raw text;
BEGIN
  raw := current_setting('request.headers', true)::json->>'x-owner-key';
  IF raw IS NULL OR raw = '' THEN
    RETURN NULL;
  END IF;
  RETURN raw::uuid;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

ALTER TABLE public.nt_folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nt_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nt_folders_select ON public.nt_folders;
DROP POLICY IF EXISTS nt_folders_insert ON public.nt_folders;
DROP POLICY IF EXISTS nt_folders_update ON public.nt_folders;
DROP POLICY IF EXISTS nt_folders_delete ON public.nt_folders;

CREATE POLICY nt_folders_select ON public.nt_folders
  FOR SELECT TO anon, authenticated
  USING (owner_key = public.nt_request_owner_key());

CREATE POLICY nt_folders_insert ON public.nt_folders
  FOR INSERT TO anon, authenticated
  WITH CHECK (owner_key = public.nt_request_owner_key());

CREATE POLICY nt_folders_update ON public.nt_folders
  FOR UPDATE TO anon, authenticated
  USING (owner_key = public.nt_request_owner_key())
  WITH CHECK (owner_key = public.nt_request_owner_key());

CREATE POLICY nt_folders_delete ON public.nt_folders
  FOR DELETE TO anon, authenticated
  USING (owner_key = public.nt_request_owner_key());

DROP POLICY IF EXISTS nt_notes_select ON public.nt_notes;
DROP POLICY IF EXISTS nt_notes_insert ON public.nt_notes;
DROP POLICY IF EXISTS nt_notes_update ON public.nt_notes;
DROP POLICY IF EXISTS nt_notes_delete ON public.nt_notes;

CREATE POLICY nt_notes_select ON public.nt_notes
  FOR SELECT TO anon, authenticated
  USING (owner_key = public.nt_request_owner_key());

CREATE POLICY nt_notes_insert ON public.nt_notes
  FOR INSERT TO anon, authenticated
  WITH CHECK (owner_key = public.nt_request_owner_key());

CREATE POLICY nt_notes_update ON public.nt_notes
  FOR UPDATE TO anon, authenticated
  USING (owner_key = public.nt_request_owner_key())
  WITH CHECK (owner_key = public.nt_request_owner_key());

CREATE POLICY nt_notes_delete ON public.nt_notes
  FOR DELETE TO anon, authenticated
  USING (owner_key = public.nt_request_owner_key());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.nt_folders TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.nt_notes TO anon, authenticated;

COMMENT ON TABLE public.nt_folders IS 'Amar Bangla Note app folders (nt_ prefix)';
COMMENT ON TABLE public.nt_notes IS 'Amar Bangla Note app notes (nt_ prefix)';;
