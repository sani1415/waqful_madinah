create table if not exists public.mdr_class_routines (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.mdr_classes(id) on delete cascade,
  version_no integer not null check (version_no > 0),
  is_current boolean not null default false,
  change_note text not null default '',
  created_by uuid references public.mdr_shared_users(id),
  created_at timestamptz not null default now(),
  constraint mdr_class_routines_class_version_uniq unique (class_id, version_no)
);

create unique index if not exists mdr_class_routines_current_uniq
  on public.mdr_class_routines (class_id)
  where is_current = true;

create index if not exists mdr_class_routines_class_created_idx
  on public.mdr_class_routines (class_id, created_at desc);

create table if not exists public.mdr_class_routine_slots (
  id uuid primary key default gen_random_uuid(),
  routine_id uuid not null references public.mdr_class_routines(id) on delete cascade,
  sort_order integer not null default 0,
  start_hour smallint not null check (start_hour between 1 and 12),
  start_minute smallint not null default 0 check (start_minute between 0 and 59),
  start_ampm text not null check (start_ampm in ('AM', 'PM')),
  end_hour smallint check (end_hour is null or end_hour between 1 and 12),
  end_minute smallint check (end_minute is null or end_minute between 0 and 59),
  end_ampm text check (end_ampm is null or end_ampm in ('AM', 'PM')),
  label text not null,
  activity_type text not null default 'other',
  constraint mdr_class_routine_slots_label_chk check (char_length(btrim(label)) > 0),
  constraint mdr_class_routine_slots_activity_chk check (
    activity_type in ('dars', 'revision', 'kitab', 'meal', 'rest', 'sports', 'admin', 'other')
  )
);

create index if not exists mdr_class_routine_slots_routine_idx
  on public.mdr_class_routine_slots (routine_id, sort_order, start_hour, start_minute);

alter table public.mdr_class_routines enable row level security;
alter table public.mdr_class_routine_slots enable row level security;

drop policy if exists "deny_all_mdr_class_routines" on public.mdr_class_routines;
create policy "deny_all_mdr_class_routines"
  on public.mdr_class_routines for all using (false) with check (false);

drop policy if exists "deny_all_mdr_class_routine_slots" on public.mdr_class_routine_slots;
create policy "deny_all_mdr_class_routine_slots"
  on public.mdr_class_routine_slots for all using (false) with check (false);;
