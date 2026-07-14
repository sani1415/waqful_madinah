create table if not exists public.mdr_divisions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique check (code in ('kitab', 'maktab')),
  created_at timestamptz not null default now()
);

create table if not exists public.mdr_classes (
  id uuid primary key default gen_random_uuid(),
  division_id uuid not null references public.mdr_divisions(id),
  name text not null,
  code text not null unique,
  roll_prefix text,
  is_iyada boolean not null default false,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.mdr_students (
  id uuid primary key default gen_random_uuid(),
  student_id text not null unique,
  name text not null,
  guardian_name text,
  guardian_phone text,
  guardian_occupation text,
  district text,
  upazila text,
  division_id uuid not null references public.mdr_divisions(id),
  current_class_id uuid not null references public.mdr_classes(id),
  current_roll text not null,
  admission_date date,
  hijri_year text,
  status text not null default 'active' check (status in ('active', 'alumni', 'dropped')),
  is_waqf boolean not null default false,
  is_hifz boolean not null default false,
  import_source text,
  old_student_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mdr_class_history (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.mdr_students(id) on delete cascade,
  class_id uuid not null references public.mdr_classes(id),
  roll text not null,
  from_date date not null,
  to_date date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.mdr_books (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.mdr_classes(id) on delete cascade,
  name text not null,
  total_pages integer,
  sort_order integer not null default 0,
  import_source text,
  old_book_id text,
  created_at timestamptz not null default now()
);

create table if not exists public.mdr_book_progress (
  id uuid primary key default gen_random_uuid(),
  book_id uuid not null references public.mdr_books(id) on delete cascade,
  pages_done integer not null default 0,
  notes text,
  updated_by uuid references public.shared_users(id),
  updated_at timestamptz not null default now(),
  unique (book_id)
);

create table if not exists public.mdr_student_import_candidates (
  id uuid primary key default gen_random_uuid(),
  source text not null check (source in ('madrasah_backup', 'moktob_backup')),
  old_student_id text not null,
  name text not null,
  guardian_name text,
  guardian_phone text,
  district text,
  upazila text,
  division_code text not null check (division_code in ('kitab', 'maktab')),
  class_code text not null,
  old_class_name text,
  old_roll text,
  old_status text,
  old_score integer,
  suggested_is_hifz boolean not null default false,
  notes text,
  candidate_status text not null default 'pending' check (candidate_status in ('pending', 'approved', 'skipped')),
  approved_student_id uuid references public.mdr_students(id),
  created_at timestamptz not null default now(),
  unique (source, old_student_id)
);

create index if not exists idx_mdr_students_class on public.mdr_students(current_class_id);
create index if not exists idx_mdr_students_import_old on public.mdr_students(import_source, old_student_id);
create index if not exists idx_mdr_import_candidates_status on public.mdr_student_import_candidates(candidate_status);
create index if not exists idx_mdr_books_class on public.mdr_books(class_id);

insert into public.mdr_divisions (name, code)
values
  ('কিতাব বিভাগ', 'kitab'),
  ('মক্তব বিভাগ', 'maktab')
on conflict (code) do nothing;

insert into public.mdr_classes (division_id, name, code, roll_prefix, is_iyada, sort_order)
select d.id, x.name, x.code, x.roll_prefix, x.is_iyada, x.sort_order
from public.mdr_divisions d
join (
  values
    ('kitab', '১ম বর্ষ', 'kitab_y1', '100', false, 10),
    ('kitab', 'ইয়াদা বর্ষ', 'kitab_iyada', 'ই', true, 20),
    ('kitab', '২য় বর্ষ', 'kitab_y2', '200', false, 30),
    ('kitab', '৩য় বর্ষ', 'kitab_y3', '300', false, 40),
    ('kitab', '৪র্থ বর্ষ', 'kitab_y4', '400', false, 50),
    ('kitab', '৫ম বর্ষ', 'kitab_y5', '500', false, 60),
    ('kitab', '৬ষ্ঠ বর্ষ', 'kitab_y6', '600', false, 70),
    ('kitab', '৭ম বর্ষ', 'kitab_y7', '700', false, 80),
    ('kitab', 'হিফজ বিভাগ', 'kitab_hifz', 'হি', false, 90),
    ('maktab', 'প্রথম শ্রেণি', 'maktab_y1', 'ম১', false, 10),
    ('maktab', 'দ্বিতীয় শ্রেণি', 'maktab_y2', 'ম২', false, 20),
    ('maktab', 'তৃতীয় শ্রেণি', 'maktab_y3', 'ম۳', false, 30),
    ('maktab', 'চতুর্থ শ্রেণি', 'maktab_y4', 'ম৪', false, 40),
    ('maktab', 'পঞ্চম শ্রেণি', 'maktab_y5', 'ম۵', false, 50)
) as x(division_code, name, code, roll_prefix, is_iyada, sort_order)
  on d.code = x.division_code
on conflict (code) do nothing;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'shared_users_class_id_fkey'
  ) then
    alter table public.shared_users
      add constraint shared_users_class_id_fkey
      foreign key (class_id)
      references public.mdr_classes(id)
      on delete set null;
  end if;
end $$;;
