-- 021_mdr_student_status_alumni.sql
-- Mid-year student status changes and alumni/withdrawal records.
-- Existing Waqf app tables are intentionally untouched.

create table if not exists public.mdr_alumni (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.mdr_students(id) on delete cascade,
  left_date date not null default current_date,
  left_type text not null default 'dropped' check (left_type in ('completed', 'dropped')),
  left_reason text not null,
  last_class_id uuid references public.mdr_classes(id),
  entered_by uuid references public.shared_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id)
);

alter table public.mdr_alumni enable row level security;

drop policy if exists "deny_all_mdr_alumni" on public.mdr_alumni;
create policy "deny_all_mdr_alumni" on public.mdr_alumni for all using (false) with check (false);

create index if not exists idx_mdr_alumni_left_date on public.mdr_alumni(left_date);
create index if not exists idx_mdr_alumni_student on public.mdr_alumni(student_id);

create or replace function public.mdr_rel_set_student_status(
  p_actor_id uuid,
  p_pin text,
  p_student_id uuid,
  p_status text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_student public.mdr_students%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_left_type text;
begin
  select *
  into v_actor
  from public.shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in ('admin', 'daftar');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  if p_status not in ('active', 'alumni', 'dropped') then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;

  select *
  into v_student
  from public.mdr_students
  where id = p_student_id;

  if v_student.id is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  if p_status in ('alumni', 'dropped') and v_reason is null then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;

  update public.mdr_students
  set status = p_status,
      updated_at = now()
  where id = p_student_id;

  if p_status in ('alumni', 'dropped') then
    v_left_type := case when p_status = 'alumni' then 'completed' else 'dropped' end;
    insert into public.mdr_alumni (
      student_id,
      left_date,
      left_type,
      left_reason,
      last_class_id,
      entered_by,
      updated_at
    )
    values (
      p_student_id,
      current_date,
      v_left_type,
      v_reason,
      v_student.current_class_id,
      v_actor.id,
      now()
    )
    on conflict (student_id) do update
    set left_date = excluded.left_date,
        left_type = excluded.left_type,
        left_reason = excluded.left_reason,
        last_class_id = excluded.last_class_id,
        entered_by = excluded.entered_by,
        updated_at = now();
  end if;

  return jsonb_build_object(
    'ok', true,
    'student_id', p_student_id,
    'status', p_status
  );
end;
$$;

create or replace function public.mdr_rel_alumni_bootstrap(p_actor_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
begin
  select *
  into v_actor
  from public.shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in ('admin', 'alumni_tracker');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  return jsonb_build_object(
    'ok', true,
    'alumni', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id,
        'student_id', s.id,
        'permanent_id', s.student_id,
        'name', s.name,
        'phone', s.guardian_phone,
        'left_date', a.left_date,
        'left_type', a.left_type,
        'left_reason', a.left_reason,
        'class_code', c.code,
        'class_name', c.name,
        'division_code', d.code,
        'status', case when a.left_type = 'completed' then 'সম্পন্ন' else 'মাঝপথে' end
      ) order by a.left_date desc, s.name), '[]'::jsonb)
      from public.mdr_alumni a
      join public.mdr_students s on s.id = a.student_id
      left join public.mdr_classes c on c.id = a.last_class_id
      left join public.mdr_divisions d on d.id = c.division_id
    )
  );
end;
$$;

grant execute on function public.mdr_rel_set_student_status(uuid, text, uuid, text, text) to anon;
grant execute on function public.mdr_rel_alumni_bootstrap(uuid, text) to anon;;
