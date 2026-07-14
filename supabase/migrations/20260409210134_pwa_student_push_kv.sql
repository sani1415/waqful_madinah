-- Allow students to save Web Push subscription metadata (one key per waqf device).
-- Apply after 002_production_rpc_rls.sql. Teacher may use any key (unchanged).

create or replace function public.madrasa_student_save_kv(p_waqf text, p_pin text, p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._madrasa_student_pin_ok(p_waqf, p_pin) then
    raise exception 'invalid_student';
  end if;
  if p_key is null or p_key !~ '^(core|goals|exams|docs_meta|academic|tnotes|pwa_push_student_[a-zA-Z0-9_]+)$' then
    raise exception 'invalid_key';
  end if;
  insert into public.app_kv (key, value, updated_at)
  values (p_key, coalesce(p_value, '{}'::jsonb), now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
end;
$$;;
