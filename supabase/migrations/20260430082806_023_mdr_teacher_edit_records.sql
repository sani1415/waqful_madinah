-- 023_mdr_teacher_edit_records.sql
-- Safe edit flow for records created by a class teacher. No delete operations.
-- Existing Waqf app tables are intentionally untouched.

alter table public.mdr_akhlaq
add column if not exists updated_at timestamptz;

alter table public.mdr_logs
add column if not exists updated_at timestamptz;

create or replace function public.mdr_rel_update_akhlaq(
  p_actor_id uuid,
  p_pin text,
  p_akhlaq_id uuid,
  p_score integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_row record;
begin
  select *
  into v_actor
  from public.shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role = 'madrasa_teacher'
    and class_id is not null;

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  if p_score is null or p_score < 0 or p_score > 100 then
    return jsonb_build_object('ok', false, 'error', 'invalid_score');
  end if;

  if btrim(coalesce(p_reason, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;

  select a.id, a.evaluated_by, s.current_class_id
  into v_row
  from public.mdr_akhlaq a
  join public.mdr_students s on s.id = a.student_id
  where a.id = p_akhlaq_id;

  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'akhlaq_not_found');
  end if;

  if v_row.evaluated_by <> v_actor.id or v_row.current_class_id <> v_actor.class_id then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  update public.mdr_akhlaq
  set score = p_score,
      reason = btrim(p_reason),
      updated_at = now()
  where id = p_akhlaq_id;

  return jsonb_build_object('ok', true, 'id', p_akhlaq_id);
end;
$$;

create or replace function public.mdr_rel_update_teacher_log(
  p_actor_id uuid,
  p_pin text,
  p_log_id uuid,
  p_content text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_row record;
begin
  select *
  into v_actor
  from public.shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role = 'madrasa_teacher'
    and class_id is not null;

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  if btrim(coalesce(p_content, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'content_required');
  end if;

  select l.id, l.written_by, coalesce(l.class_id, s.current_class_id) as scope_class_id
  into v_row
  from public.mdr_logs l
  left join public.mdr_students s on s.id = l.student_id
  where l.id = p_log_id;

  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'log_not_found');
  end if;

  if v_row.written_by <> v_actor.id or v_row.scope_class_id <> v_actor.class_id then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  update public.mdr_logs
  set content = btrim(p_content),
      updated_at = now()
  where id = p_log_id;

  return jsonb_build_object('ok', true, 'id', p_log_id);
end;
$$;

grant execute on function public.mdr_rel_update_akhlaq(uuid, text, uuid, integer, text) to anon;
grant execute on function public.mdr_rel_update_teacher_log(uuid, text, uuid, text) to anon;;
