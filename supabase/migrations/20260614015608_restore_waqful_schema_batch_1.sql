-- Run this in Supabase → SQL Editor (once), then apply supabase/002_production_rpc_rls.sql for production.

create table if not exists public.app_kv (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.app_kv enable row level security;

drop policy if exists "anon_all_app_kv" on public.app_kv;
create policy "anon_all_app_kv" on public.app_kv
  for all to anon
  using (true) with check (true);

-- Public file bucket for chat/docs (MVP). Switch to private + signed URLs later.
insert into storage.buckets (id, name, public)
values ('waqf-files', 'waqf-files', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "waqf_files_select" on storage.objects;
drop policy if exists "waqf_files_insert" on storage.objects;
drop policy if exists "waqf_files_update" on storage.objects;
drop policy if exists "waqf_files_delete" on storage.objects;

create policy "waqf_files_select" on storage.objects
  for select to anon using (bucket_id = 'waqf-files');
create policy "waqf_files_insert" on storage.objects
  for insert to anon with check (bucket_id = 'waqf-files');
create policy "waqf_files_update" on storage.objects
  for update to anon using (bucket_id = 'waqf-files') with check (bucket_id = 'waqf-files');
create policy "waqf_files_delete" on storage.objects
  for delete to anon using (bucket_id = 'waqf-files');


-- Production: close direct anon access to app_kv; use SECURITY DEFINER RPCs (PIN-gated).
-- Apply after 001_app_kv_and_storage.sql.
-- App must set window.__MADRASA_ROLE__ = 'teacher' | 'student' on teacher.html / student.html.

-- Internal: full KV snapshot (no auth). Called only from other SECURITY DEFINER functions.
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

-- Student: full data except teacher_pin (never sent to browser).
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

update storage.buckets set public = false where id = 'waqf-files';


-- Lock screen: students with unread teacher→student messages (no PINs).
-- Restores "অপেক্ষারত" before login while app_kv stays closed to direct anon reads.

create or replace function public.madrasa_student_lock_hints()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  core_val jsonb;
  stud jsonb;
  sid text;
  thread jsonb;
  msg jsonb;
  n int;
  hints jsonb := '[]'::jsonb;
  one jsonb;
begin
  select value into core_val from public.app_kv where key = 'core';
  if core_val is null then return '[]'::jsonb; end if;

  for stud in select * from jsonb_array_elements(coalesce(core_val->'students', '[]'::jsonb))
  loop
    sid := stud->>'id';
    if sid is null then continue; end if;
    thread := core_val->'chats'->sid;
    n := 0;
    if thread is not null and jsonb_typeof(thread) = 'array' then
      for msg in select * from jsonb_array_elements(thread)
      loop
        if (msg->>'role') = 'out' and coalesce((msg->>'read')::boolean, false) = false then
          n := n + 1;
        end if;
      end loop;
    end if;
    if n > 0 then
      one := jsonb_build_object(
        'id', sid,
        'name', coalesce(stud->>'name', ''),
        'waqfId', coalesce(stud->>'waqfId', ''),
        'color', coalesce(stud->>'color', '#1565C0'),
        'unread', n
      );
      hints := hints || jsonb_build_array(one);
    end if;
  end loop;
  return hints;
end;
$$;

grant execute on function public.madrasa_student_lock_hints() to anon, authenticated;


-- Future: Capacitor (@capacitor/push-notifications) + FCM — store device tokens for server-side sends.
-- Not used by the web app yet. Wire via RPC + Edge Function (service role) when implementing push.

create table if not exists public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  platform text,
  fcm_token text not null,
  student_waqf text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (fcm_token)
);

comment on table public.device_push_tokens is 'Reserved for FCM/Capacitor push — app does not read/write yet.';

alter table public.device_push_tokens enable row level security;

-- No anon policies: registration and sends will use service role or authenticated RPCs later.


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
$$;
;
