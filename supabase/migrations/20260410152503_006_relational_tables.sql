-- ══════════════════════════════════════════════
-- 006_relational_tables.sql
-- JSON blob → relational schema migration
-- ══════════════════════════════════════════════

-- ── madrasa_config ────────────────────────────
CREATE TABLE IF NOT EXISTS public.madrasa_config (
  id          text PRIMARY KEY DEFAULT 'singleton',
  teacher_name text NOT NULL DEFAULT '',
  madrasa_name text NOT NULL DEFAULT 'Waqful Madinah',
  teacher_pin  text NOT NULL DEFAULT '1234',
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ── students ──────────────────────────────────
CREATE TABLE IF NOT EXISTS public.students (
  id              text PRIMARY KEY,
  waqf_id         text UNIQUE NOT NULL,
  name            text NOT NULL,
  cls             text NOT NULL DEFAULT '',
  roll            text NOT NULL DEFAULT '',
  pin             text NOT NULL,
  color           text NOT NULL DEFAULT '#128C7E',
  note            text NOT NULL DEFAULT '',
  father_name     text NOT NULL DEFAULT '',
  father_occupation text NOT NULL DEFAULT '',
  contact         text NOT NULL DEFAULT '',
  district        text NOT NULL DEFAULT '',
  upazila         text NOT NULL DEFAULT '',
  blood_group     text NOT NULL DEFAULT '',
  enrollment_date date,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS students_pin_idx ON public.students(pin);

-- ── messages ──────────────────────────────────
CREATE TABLE IF NOT EXISTS public.messages (
  id          text PRIMARY KEY,
  thread_id   text NOT NULL,
  role        text NOT NULL CHECK (role IN ('out', 'in')),
  type        text NOT NULL DEFAULT 'text',
  text        text NOT NULL DEFAULT '',
  extra       jsonb NOT NULL DEFAULT '{}',
  is_read     boolean NOT NULL DEFAULT false,
  sent_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS messages_thread_idx ON public.messages(thread_id, sent_at);

-- ── tasks ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tasks (
  id          text PRIMARY KEY,
  title       text NOT NULL,
  description text NOT NULL DEFAULT '',
  type        text NOT NULL DEFAULT 'onetime' CHECK (type IN ('onetime', 'daily')),
  deadline    date,
  created_at  date NOT NULL DEFAULT CURRENT_DATE
);

-- ── task_assignments ──────────────────────────
CREATE TABLE IF NOT EXISTS public.task_assignments (
  id          text PRIMARY KEY,
  task_id     text NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  student_id  text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'late')),
  completed_date date,
  completed_time text,
  UNIQUE(task_id, student_id)
);
CREATE INDEX IF NOT EXISTS task_assignments_student_idx ON public.task_assignments(student_id);

-- ── goals ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.goals (
  id          text PRIMARY KEY,
  student_id  text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  title       text NOT NULL,
  cat         text NOT NULL DEFAULT 'other',
  deadline    date,
  note        text NOT NULL DEFAULT '',
  done        boolean NOT NULL DEFAULT false,
  created_at  date NOT NULL DEFAULT CURRENT_DATE
);
CREATE INDEX IF NOT EXISTS goals_student_idx ON public.goals(student_id);

-- ── quizzes ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.quizzes (
  id            text PRIMARY KEY,
  title         text NOT NULL,
  subject       text NOT NULL DEFAULT '',
  description   text NOT NULL DEFAULT '',
  time_limit    integer NOT NULL DEFAULT 30,
  pass_percent  integer NOT NULL DEFAULT 60,
  deadline      date,
  created_at    date NOT NULL DEFAULT CURRENT_DATE
);

-- ── quiz_questions ────────────────────────────
CREATE TABLE IF NOT EXISTS public.quiz_questions (
  id          text PRIMARY KEY,
  quiz_id     text NOT NULL REFERENCES public.quizzes(id) ON DELETE CASCADE,
  sort_order  integer NOT NULL DEFAULT 0,
  type        text NOT NULL,
  text        text NOT NULL,
  options     jsonb NOT NULL DEFAULT '[]',
  correct_answer text,
  marks       integer NOT NULL DEFAULT 1,
  upload_instructions text
);
CREATE INDEX IF NOT EXISTS quiz_questions_quiz_idx ON public.quiz_questions(quiz_id, sort_order);

-- ── quiz_assignees ────────────────────────────
CREATE TABLE IF NOT EXISTS public.quiz_assignees (
  quiz_id     text NOT NULL REFERENCES public.quizzes(id) ON DELETE CASCADE,
  student_id  text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  PRIMARY KEY (quiz_id, student_id)
);

-- ── quiz_submissions ──────────────────────────
CREATE TABLE IF NOT EXISTS public.quiz_submissions (
  id              text PRIMARY KEY,
  quiz_id         text NOT NULL REFERENCES public.quizzes(id) ON DELETE CASCADE,
  student_id      text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  student_name    text NOT NULL DEFAULT '',
  answers         jsonb NOT NULL DEFAULT '{}',
  score           integer NOT NULL DEFAULT 0,
  total           integer NOT NULL DEFAULT 0,
  passed          boolean NOT NULL DEFAULT false,
  needs_manual_grade boolean NOT NULL DEFAULT false,
  submitted_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE(quiz_id, student_id)
);

-- ── documents ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.documents (
  id            text PRIMARY KEY,
  student_id    text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  student_name  text NOT NULL DEFAULT '',
  file_name     text NOT NULL,
  file_type     text NOT NULL DEFAULT '',
  file_size     bigint NOT NULL DEFAULT 0,
  category      text NOT NULL DEFAULT 'general',
  note          text NOT NULL DEFAULT '',
  storage_path  text,
  file_url      text,
  is_read       boolean NOT NULL DEFAULT false,
  uploaded_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS documents_student_idx ON public.documents(student_id);

-- ── academic_history ──────────────────────────
CREATE TABLE IF NOT EXISTS public.academic_history (
  id          text PRIMARY KEY,
  student_id  text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  year_class  text NOT NULL,
  grade       text NOT NULL,
  added_at    date NOT NULL DEFAULT CURRENT_DATE
);

-- ── teacher_notes ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.teacher_notes (
  id          text PRIMARY KEY,
  student_id  text NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  text        text NOT NULL,
  note_date   date NOT NULL DEFAULT CURRENT_DATE,
  note_time   text NOT NULL DEFAULT '',
  edited_at   date
);
CREATE INDEX IF NOT EXISTS teacher_notes_student_idx ON public.teacher_notes(student_id);

-- ── pwa_subscriptions ─────────────────────────
CREATE TABLE IF NOT EXISTS public.pwa_subscriptions (
  id          text PRIMARY KEY,
  role        text NOT NULL CHECK (role IN ('teacher', 'student')),
  subscription jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);;
