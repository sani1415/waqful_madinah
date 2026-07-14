-- Harden admin/staff PIN changes in shared_users.

create or replace function public.mdr_rel_staff_change_own_pin(
  p_user_id uuid,
  p_current_pin text,
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_current text := btrim(coalesce(p_current_pin, ''));
  v_new text := btrim(coalesce(p_new_pin, ''));
  v_n int;
begin
  if p_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'missing_user');
  end if;

  if not private.verify_user_pin(p_user_id, v_current) then
    return jsonb_build_object('ok', false, 'error', 'invalid_current_pin');
  end if;

  if length(v_new) <> 4 or v_new !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_new_pin');
  end if;

  if v_new = v_current then
    return jsonb_build_object('ok', false, 'error', 'same_pin');
  end if;

  update public.shared_users
  set pin = v_new,
      updated_at = now()
  where id = p_user_id
    and is_active = true
    and role <> 'admin';

  get diagnostics v_n = ROW_COUNT;
  if v_n <> 1 then
    return jsonb_build_object('ok', false, 'error', 'update_failed');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.mdr_rel_staff_change_own_pin(uuid, text, text) to anon;

create or replace function public.mdr_rel_admin_change_pin(
  p_current_pin text,
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_current text := btrim(coalesce(p_current_pin, ''));
  v_new text := btrim(coalesce(p_new_pin, ''));
  v_n int;
begin
  if not private.verify_admin_pin(v_current) then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  if length(v_new) <> 4 or v_new !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_new_pin');
  end if;

  if v_new = v_current then
    return jsonb_build_object('ok', false, 'error', 'same_pin');
  end if;

  update public.shared_users
  set pin = v_new,
      updated_at = now()
  where role = 'admin'
    and is_active = true;

  get diagnostics v_n = ROW_COUNT;
  if v_n < 1 then
    return jsonb_build_object('ok', false, 'error', 'no_admin_user');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.mdr_rel_admin_change_pin(text, text) to anon;;
