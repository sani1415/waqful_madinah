alter table public.mdr_class_routines add column if not exists updated_at timestamptz not null default now();

create or replace function private.mdr_class_routine_validate_slots(p_slots jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
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
  if p_slots is null or jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    return jsonb_build_object('ok', false, 'error', 'slots_required');
  end if;
  for v_slot in select value from jsonb_array_elements(p_slots)
  loop
    v_idx := v_idx + 1;
    v_label := nullif(btrim(coalesce(v_slot->>'label', '')), '');
    if v_label is null then return jsonb_build_object('ok', false, 'error', 'invalid_slot_label', 'index', v_idx); end if;
    v_start_hour := (v_slot->>'start_hour')::integer;
    v_start_minute := coalesce((v_slot->>'start_minute')::integer, 0);
    v_start_ampm := upper(coalesce(v_slot->>'start_ampm', ''));
    if v_start_hour is null or v_start_hour < 1 or v_start_hour > 12 or v_start_minute < 0 or v_start_minute > 59 or v_start_ampm not in ('AM', 'PM') then
      return jsonb_build_object('ok', false, 'error', 'invalid_start_time', 'index', v_idx);
    end if;
    if v_slot ? 'end_hour' and nullif(v_slot->>'end_hour', '') is not null then
      v_end_hour := (v_slot->>'end_hour')::integer;
      v_end_minute := coalesce((v_slot->>'end_minute')::integer, 0);
      v_end_ampm := upper(coalesce(v_slot->>'end_ampm', ''));
      if v_end_hour < 1 or v_end_hour > 12 or v_end_minute < 0 or v_end_minute > 59 or v_end_ampm not in ('AM', 'PM') then
        return jsonb_build_object('ok', false, 'error', 'invalid_end_time', 'index', v_idx);
      end if;
    end if;
    v_activity := coalesce(nullif(btrim(v_slot->>'activity_type'), ''), 'other');
    if v_activity not in ('dars', 'revision', 'kitab', 'meal', 'rest', 'sports', 'admin', 'other') then
      return jsonb_build_object('ok', false, 'error', 'invalid_activity_type', 'index', v_idx);
    end if;
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function private.mdr_class_routine_insert_slots(p_routine_id uuid, p_slots jsonb)
returns void language plpgsql security definer set search_path = public, private as $$
declare v_slot jsonb; v_idx integer := 0; begin
  for v_slot in select value from jsonb_array_elements(p_slots) loop
    v_idx := v_idx + 1;
    insert into public.mdr_class_routine_slots (routine_id, sort_order, start_hour, start_minute, start_ampm, end_hour, end_minute, end_ampm, label, activity_type)
    values (p_routine_id, coalesce((v_slot->>'sort_order')::integer, v_idx), (v_slot->>'start_hour')::integer, coalesce((v_slot->>'start_minute')::integer,0), upper(v_slot->>'start_ampm'),
      case when v_slot ? 'end_hour' and nullif(v_slot->>'end_hour','') is not null then (v_slot->>'end_hour')::integer else null end,
      case when v_slot ? 'end_hour' and nullif(v_slot->>'end_hour','') is not null then coalesce((v_slot->>'end_minute')::integer,0) else null end,
      case when v_slot ? 'end_hour' and nullif(v_slot->>'end_hour','') is not null then upper(v_slot->>'end_ampm') else null end,
      btrim(v_slot->>'label'), coalesce(nullif(btrim(v_slot->>'activity_type'),''),'other'));
  end loop;
end; $$;;
