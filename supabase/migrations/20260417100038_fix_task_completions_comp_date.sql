alter table public.task_completions
  add column if not exists comp_date date;

update public.task_completions
set comp_date = "date"
where comp_date is null;

alter table public.task_completions
  alter column comp_date set not null;

create unique index if not exists task_completions_task_student_comp_date_uniq
  on public.task_completions (task_id, student_id, comp_date);

create index if not exists task_completions_student_date_idx
  on public.task_completions (student_id, comp_date);

create index if not exists task_completions_task_date_idx
  on public.task_completions (task_id, comp_date);;
