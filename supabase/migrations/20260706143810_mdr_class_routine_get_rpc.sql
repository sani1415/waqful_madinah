create or replace function public.mdr_rel_class_routine_get(
  p_actor_id uuid,
  p_pin text,
  p_class_code text default null,
  p_routine_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_teacher public.mdr_shared_users%rowtype;
  v_class public.mdr_classes%rowtype;
  v_target_routine public.mdr_class_routines%rowtype;
  v_current public.mdr_class_routines%rowtype;
begin
  select * into v_teacher
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role = 'madrasa_teacher'
    and class_id is not null;

  if v_teacher.id is not null then
    select * into v_class from public.mdr_classes where id = v_teacher.class_id and is_active = true;
  elsif nullif(btrim(coalesce(p_class_code, '')), '') is not null then
    select * into v_class from public.mdr_classes where code = btrim(p_class_code) and is_active = true;
  else
    return jsonb_build_object('ok', false, 'error', 'class_not_found');
  end if;

  if v_class.id is null then
    return jsonb_build_object('ok', false, 'error', 'class_not_found');
  end if;

  if not private.mdr_class_routine_can_read(p_actor_id, p_pin, v_class.id) then
    return jsonb_build_object('ok', false, 'error', 'permission_denied');
  end if;

  select * into v_current
  from public.mdr_class_routines
  where class_id = v_class.id and is_current = true
  limit 1;

  if p_routine_id is not null then
    select * into v_target_routine
    from public.mdr_class_routines
    where id = p_routine_id and class_id = v_class.id;
    if v_target_routine.id is null then
      return jsonb_build_object('ok', false, 'error', 'routine_not_found');
    end if;
  else
    v_target_routine := v_current;
  end if;

  return jsonb_build_object(
    'ok', true,
    'class_id', v_class.id,
    'class_code', v_class.code,
    'class_name', v_class.name,
    'current', case
      when v_current.id is null then null
      else jsonb_build_object(
        'id', v_current.id,
        'version_no', v_current.version_no,
        'is_current', true,
        'change_note', v_current.change_note,
        'created_at', v_current.created_at,
        'slots', private.mdr_class_routine_slots_json(v_current.id)
      )
    end,
    'viewing', case
      when v_target_routine.id is null then null
      else jsonb_build_object(
        'id', v_target_routine.id,
        'version_no', v_target_routine.version_no,
        'is_current', v_target_routine.is_current,
        'change_note', v_target_routine.change_note,
        'created_at', v_target_routine.created_at,
        'slots', private.mdr_class_routine_slots_json(v_target_routine.id)
      )
    end,
    'versions', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id,
        'version_no', r.version_no,
        'is_current', r.is_current,
        'change_note', r.change_note,
        'created_at', r.created_at,
        'slot_count', (
          select count(*)::integer
          from public.mdr_class_routine_slots s
          where s.routine_id = r.id
        )
      ) order by r.version_no desc), '[]'::jsonb)
      from public.mdr_class_routines r
      where r.class_id = v_class.id
    )
  );
end;
$$;

revoke execute on function public.mdr_rel_class_routine_get(uuid, text, text, uuid) from public, authenticated;
grant execute on function public.mdr_rel_class_routine_get(uuid, text, text, uuid) to anon;;
