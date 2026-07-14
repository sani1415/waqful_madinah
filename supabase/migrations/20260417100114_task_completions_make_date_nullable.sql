alter table public.task_completions
  alter column "date" drop not null;

-- keep date in sync for older code paths
update public.task_completions
set "date" = comp_date
where "date" is null and comp_date is not null;;
