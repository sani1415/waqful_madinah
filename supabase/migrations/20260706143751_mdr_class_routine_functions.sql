create or replace function private.mdr_routine_time_sort_key(
  p_hour smallint,
  p_minute smallint,
  p_ampm text
)
returns integer
language sql
immutable
as $$
  select
    case
      when p_ampm = 'AM' and p_hour = 12 then p_minute
      when p_ampm = 'AM' then (p_hour * 60 + p_minute)
      when p_hour = 12 then (12 * 60 + p_minute)
      else ((p_hour + 12) * 60 + p_minute)
    end;
$$;

create or replace function private.mdr_class_routine_slots_json(p_routine_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'sort_order', s.sort_order,
    'start_hour', s.start_hour,
    'start_minute', s.start_minute,
    'start_ampm', s.start_ampm,
    'end_hour', s.end_hour,
    'end_minute', s.end_minute,
    'end_ampm', s.end_ampm,
    'label', s.label,
    'activity_type', s.activity_type
  ) order by
    s.sort_order,
    private.mdr_routine_time_sort_key(s.start_hour, s.start_minute, s.start_ampm),
    s.label), '[]'::jsonb)
  from public.mdr_class_routine_slots s
  where s.routine_id = p_routine_id;
$$;

create or replace function private.mdr_class_routine_can_read(
  p_actor_id uuid,
  p_pin text,
  p_class_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_teacher public.mdr_shared_users%rowtype;
  v_admin public.mdr_shared_users%rowtype;
  v_division_code text;
  v_depts text[];
  v_is_super boolean;
begin
  if p_class_id is null then
    return false;
  end if;

  select * into v_teacher
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role = 'madrasa_teacher'
    and class_id = p_class_id;

  if v_teacher.id is not null then
    return true;
  end if;

  v_admin := private.mdr_admin_dashboard_actor(p_actor_id, p_pin);
  if v_admin.id is null then
    return false;
  end if;

  v_is_super := v_admin.role = 'admin'
    or coalesce(v_admin.admin_perms->>'super_admin', 'false') = 'true';

  if not v_is_super
     and coalesce(v_admin.admin_perms->'permissions'->>'dars', 'false') <> 'true' then
    return false;
  end if;

  if v_is_super then
    v_depts := array['kitab', 'maktab']::text[];
  else
    select array(
      select value
      from jsonb_array_elements_text(coalesce(v_admin.admin_perms->'scope'->'madrasa_depts', '[]'::jsonb)) as t(value)
      where value in ('kitab', 'maktab')
    ) into v_depts;
  end if;

  if coalesce(array_length(v_depts, 1), 0) = 0 then
    return false;
  end if;

  select d.code
  into v_division_code
  from public.mdr_classes c
  join public.mdr_divisions d on d.id = c.division_id
  where c.id = p_class_id
    and c.is_active = true
    and c.code <> 'kitab_hifz';

  return v_division_code = any(v_depts);
end;
$$;;
