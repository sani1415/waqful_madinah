create or replace function public.mdr_rel_class_routine_save(
  p_actor_id uuid,
  p_pin text,
  p_slots jsonb,
  p_change_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_class public.mdr_classes%rowtype;
  v_next_version integer;
  v_routine_id uuid;
  v_slot jsonb;
  v_idx integer := 0;
  v_label text;
  v_start_hour integer;
  v_start_minute integer;
  v_start_ampm text;
  v_end_hour integer;
  v_end_minute integer;
  v_end_ampm text;
  v_activity text;
begin
  select * into v_actor
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role = 'madrasa_teacher'
    and class_id is not null;

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  select * into v_class from public.mdr_classes where id = v_actor.class_id and is_active = true;
  if v_class.id is null then
    return jsonb_build_object('ok', false, 'error', 'class_not_found');
  end if;

  if p_slots is null or jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    return jsonb_build_object('ok', false, 'error', 'slots_required');
  end if;

  for v_slot in select value from jsonb_array_elements(p_slots)
  loop
    v_idx := v_idx + 1;
    v_label := nullif(btrim(coalesce(v_slot->>'label', '')), '');
    if v_label is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_slot_label', 'index', v_idx);
    end if;

    v_start_hour := (v_slot->>'start_hour')::integer;
    v_start_minute := coalesce((v_slot->>'start_minute')::integer, 0);
    v_start_ampm := upper(coalesce(v_slot->>'start_ampm', ''));
    if v_start_hour is null or v_start_hour < 1 or v_start_hour > 12
       or v_start_minute < 0 or v_start_minute > 59
       or v_start_ampm not in ('AM', 'PM') then
      return jsonb_build_object('ok', false, 'error', 'invalid_start_time', 'index', v_idx);
    end if;

    if v_slot ? 'end_hour' and nullif(v_slot->>'end_hour', '') is not null then
      v_end_hour := (v_slot->>'end_hour')::integer;
      v_end_minute := coalesce((v_slot->>'end_minute')::integer, 0);
      v_end_ampm := upper(coalesce(v_slot->>'end_ampm', ''));
      if v_end_hour < 1 or v_end_hour > 12
         or v_end_minute < 0 or v_end_minute > 59
         or v_end_ampm not in ('AM', 'PM') then
        return jsonb_build_object('ok', false, 'error', 'invalid_end_time', 'index', v_idx);
      end if;
    else
      v_end_hour := null;
      v_end_minute := null;
      v_end_ampm := null;
    end if;

    v_activity := coalesce(nullif(btrim(v_slot->>'activity_type'), ''), 'other');
    if v_activity not in ('dars', 'revision', 'kitab', 'meal', 'rest', 'sports', 'admin', 'other') then
      return jsonb_build_object('ok', false, 'error', 'invalid_activity_type', 'index', v_idx);
    end if;
  end loop;

  select coalesce(max(version_no), 0) + 1
  into v_next_version
  from public.mdr_class_routines
  where class_id = v_class.id;

  update public.mdr_class_routines
  set is_current = false
  where class_id = v_class.id and is_current = true;

  insert into public.mdr_class_routines (class_id, version_no, is_current, change_note, created_by)
  values (
    v_class.id,
    v_next_version,
    true,
    coalesce(nullif(btrim(coalesce(p_change_note, '')), ''), ''),
    v_actor.id
  )
  returning id into v_routine_id;

  v_idx := 0;
  for v_slot in select value from jsonb_array_elements(p_slots)
  loop
    v_idx := v_idx + 1;
    v_label := btrim(v_slot->>'label');
    v_start_hour := (v_slot->>'start_hour')::integer;
    v_start_minute := coalesce((v_slot->>'start_minute')::integer, 0);
    v_start_ampm := upper(v_slot->>'start_ampm');
    if v_slot ? 'end_hour' and nullif(v_slot->>'end_hour', '') is not null then
      v_end_hour := (v_slot->>'end_hour')::integer;
      v_end_minute := coalesce((v_slot->>'end_minute')::integer, 0);
      v_end_ampm := upper(v_slot->>'end_ampm');
    else
      v_end_hour := null;
      v_end_minute := null;
      v_end_ampm := null;
    end if;
    v_activity := coalesce(nullif(btrim(v_slot->>'activity_type'), ''), 'other');

    insert into public.mdr_class_routine_slots (
      routine_id, sort_order, start_hour, start_minute, start_ampm,
      end_hour, end_minute, end_ampm, label, activity_type
    )
    values (
      v_routine_id,
      coalesce((v_slot->>'sort_order')::integer, v_idx),
      v_start_hour,
      v_start_minute,
      v_start_ampm,
      v_end_hour,
      v_end_minute,
      v_end_ampm,
      v_label,
      v_activity
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'routine_id', v_routine_id,
    'version_no', v_next_version
  );
end;
$$;

revoke execute on function public.mdr_rel_class_routine_save(uuid, text, jsonb, text) from public, authenticated;
grant execute on function public.mdr_rel_class_routine_save(uuid, text, jsonb, text) to anon;;
