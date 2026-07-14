-- Shared access for nt_ app until auth is added

DROP POLICY IF EXISTS nt_folders_select ON public.nt_folders;
DROP POLICY IF EXISTS nt_folders_insert ON public.nt_folders;
DROP POLICY IF EXISTS nt_folders_update ON public.nt_folders;
DROP POLICY IF EXISTS nt_folders_delete ON public.nt_folders;
DROP POLICY IF EXISTS nt_notes_select ON public.nt_notes;
DROP POLICY IF EXISTS nt_notes_insert ON public.nt_notes;
DROP POLICY IF EXISTS nt_notes_update ON public.nt_notes;
DROP POLICY IF EXISTS nt_notes_delete ON public.nt_notes;

CREATE POLICY nt_folders_shared ON public.nt_folders
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

CREATE POLICY nt_notes_shared ON public.nt_notes
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

COMMENT ON TABLE public.nt_folders IS 'Amar Bangla Note — shared access (no auth yet)';
COMMENT ON TABLE public.nt_notes IS 'Amar Bangla Note — shared access (no auth yet)';;
