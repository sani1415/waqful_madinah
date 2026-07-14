
CREATE TABLE public.task_completions (
  id            text        PRIMARY KEY,
  task_id       text        NOT NULL REFERENCES public.tasks(id)    ON DELETE CASCADE,
  student_id    text        NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  date          date        NOT NULL,
  status        text        NOT NULL CHECK (status IN ('done', 'missed', 'partial')),
  completed_at  timestamptz,
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, student_id, date)
);

CREATE INDEX idx_tc_student_date ON public.task_completions (student_id, date DESC);
CREATE INDEX idx_tc_task_date    ON public.task_completions (task_id,    date DESC);
CREATE INDEX idx_tc_date         ON public.task_completions (date        DESC);

ALTER TABLE public.task_completions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tc_deny_all ON public.task_completions FOR ALL USING (false);

ALTER PUBLICATION supabase_realtime ADD TABLE public.task_completions;
;
