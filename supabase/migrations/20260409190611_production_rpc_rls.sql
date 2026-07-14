create or replace function public._madrasa_kv_bundle()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'core', coalesce((select value from public.app_kv where key = 'core'), '{}'::jsonb),
    'goals', coalesce((select value from public.app_kv where key = 'goals'), '{}'::jsonb),
    'exams', coalesce((select value from public.app_kv where key = 'exams'), '{"quizzes":[],"submissions":[]}'::jsonb),
    'docs_meta', coalesce((select value from public.app_kv where key = 'docs_meta'), '[]'::jsonb),
    'academic', coalesce((select value from public.app_kv where key = 'academic'), '{}'::jsonb),
    'tnotes', coalesce((select value from public.app_kv where key = 'tnotes'), '{}'::jsonb),
    'teacher_pin', coalesce((select value from public.app_kv where key = 'teacher_pin'), '{"pin":""}'::jsonb)
  );
$$;

revoke all on function public._madrasa_kv_bundle() from public;

create or replace function public.madrasa_normalize_waqf(raw text)
returns text
language plpgsql
immutable
as $$
declare
  t text;
  n int;
begin
  t := lower(trim(regexp_replace(coalesce(raw, ''), '\s', '', 'g')));
  if t = '' then return null; end if;
  if left(t, 5) = 'waqf_' then
    n := (substring(t from 6))::int;
  else
    n := t::int;
  end if;
  if n < 0 then return null; end if;
  return 'waqf_' || lpad(n::text, 3, '0');
exception when others then
  return null;
end;
$$;

create or replace function public._madrasa_stored_teacher_pin()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select value->>'pin' from public.app_kv where key = 'teacher_pin' limit 1),
    ''
  );
$$;

create or replace function public._madrasa_teacher_pin_ok(p_teacher_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  stored text;
begin
  stored := public._madrasa_stored_teacher_pin();
  if stored is null or stored = '' then
    stored := '1234';
  end if;
  return p_teacher_pin is not null and p_teacher_pin = stored;
end;
$$;

create or replace function public._madrasa_student_pin_ok(p_waqf text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  core_val jsonb;
  elem jsonb;
  norm text;
begin
  norm := public.madrasa_normalize_waqf(p_waqf);
  if norm is null or p_pin is null or p_pin = '' then return false; end if;
  select value into core_val from public.app_kv where key = 'core';
  if core_val is null then return false; end if;
  for elem in select * from jsonb_array_elements(coalesce(core_val->'students', '[]'::jsonb))
  loop
    if (elem->>'waqfId') = norm and (elem->>'pin') = p_pin then
      return true;
    end if;
  end loop;
  return false;
end;
$$;

create or replace function public.madrasa_public_branding()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  core_val jsonb;
  m text;
begin
  select value into core_val from public.app_kv where key = 'core';
  m := coalesce(core_val->'teacher'->>'madrasa', 'Waqful Madinah');
  return jsonb_build_object('madrasa', m);
end;
$$;

create or replace function public.madrasa_teacher_bootstrap(p_teacher_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._madrasa_teacher_pin_ok(p_teacher_pin) then
    raise exception 'invalid_teacher_pin';
  end if;
  return public._madrasa_kv_bundle();
end;
$$;

create or replace function public.madrasa_teacher_save_kv(p_teacher_pin text, p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._madrasa_teacher_pin_ok(p_teacher_pin) then
    raise exception 'invalid_teacher_pin';
  end if;
  if p_key is null or p_key = '' then
    raise exception 'invalid_key';
  end if;
  insert into public.app_kv (key, value, updated_at)
  values (p_key, coalesce(p_value, '{}'::jsonb), now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
end;
$$;

create or replace function public.madrasa_student_bootstrap(p_waqf text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._madrasa_student_pin_ok(p_waqf, p_pin) then
    raise exception 'invalid_student';
  end if;
  return public._madrasa_kv_bundle() - 'teacher_pin';
end;
$$;

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
  if p_key is null or p_key !~ '^(core|goals|exams|docs_meta|academic|tnotes)$' then
    raise exception 'invalid_key';
  end if;
  insert into public.app_kv (key, value, updated_at)
  values (p_key, coalesce(p_value, '{}'::jsonb), now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
end;
$$;

grant execute on function public.madrasa_public_branding() to anon, authenticated;
grant execute on function public.madrasa_teacher_bootstrap(text) to anon, authenticated;
grant execute on function public.madrasa_teacher_save_kv(text, text, jsonb) to anon, authenticated;
grant execute on function public.madrasa_student_bootstrap(text, text) to anon, authenticated;
grant execute on function public.madrasa_student_save_kv(text, text, text, jsonb) to anon, authenticated;

drop policy if exists "anon_all_app_kv" on public.app_kv;

update storage.buckets set public = false where id = 'waqf-files';;
