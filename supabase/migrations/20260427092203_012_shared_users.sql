create schema if not exists private;

create table if not exists public.shared_users (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  pin text not null,
  role text not null check (
    role in (
      'admin',
      'dept_head',
      'madrasa_teacher',
      'daftar',
      'khedmat',
      'library',
      'alumni_tracker',
      'hifz'
    )
  ),
  module_access text[] not null default '{}',
  admin_perms jsonb not null default '{}'::jsonb,
  dept_code text,
  class_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.shared_users enable row level security;

drop policy if exists "deny_all_shared_users" on public.shared_users;
create policy "deny_all_shared_users"
on public.shared_users
for all
using (false)
with check (false);

create or replace function private.verify_admin_pin(p_pin text)
returns boolean
language sql
security definer
set search_path = public, private
as $$
  select exists (
    select 1
    from public.shared_users u
    where u.role = 'admin'
      and u.is_active = true
      and u.pin = p_pin
  );
$$;

create or replace function private.verify_user_pin(p_user_id uuid, p_pin text)
returns boolean
language sql
security definer
set search_path = public, private
as $$
  select exists (
    select 1
    from public.shared_users u
    where u.id = p_user_id
      and u.is_active = true
      and u.pin = p_pin
  );
$$;

insert into public.shared_users (name, pin, role, module_access, admin_perms)
select 'জিম্মাদার', '0000', 'admin', array['admin', 'madrasa'], '{"super_admin": true}'::jsonb
where not exists (
  select 1 from public.shared_users where role = 'admin'
);;
