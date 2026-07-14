-- Department table, RLS, seed data, and RPCs for the Dept module.

create table if not exists public.dept_departments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  code       text not null unique,
  emoji      text not null default '🏢',
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.dept_departments enable row level security;

drop policy if exists "deny_all_dept_departments" on public.dept_departments;
create policy "deny_all_dept_departments" on public.dept_departments
  for all using (false) with check (false);

insert into public.dept_departments (name, code, emoji, sort_order) values
  ('কৃষি বিভাগ',   'dept_1', '🌾', 1),
  ('মধু বিভাগ',    'dept_2', '🍯', 2),
  ('বেকারি বিভাগ', 'dept_3', '🍞', 3),
  ('সেলাই বিভাগ',  'dept_4', '🧵', 4)
on conflict (code) do nothing;

create or replace function public.dept_rel_list_departments()
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select jsonb_build_object(
    'ok', true,
    'departments', coalesce(
      (select jsonb_agg(
        jsonb_build_object(
          'id',         d.id,
          'name',       d.name,
          'code',       d.code,
          'emoji',      d.emoji,
          'sort_order', d.sort_order
        ) order by d.sort_order, d.name
      )
      from public.dept_departments d
      where d.is_active = true),
      '[]'::jsonb
    )
  );
$$;

grant execute on function public.dept_rel_list_departments() to anon;

create or replace function public.dept_rel_save_department(
  p_pin       text,
  p_id        uuid    default null,
  p_name      text    default '',
  p_emoji     text    default '🏢',
  p_code      text    default null,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_id   uuid;
  v_code text;
begin
  if not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;

  if p_id is not null then
    update public.dept_departments
    set name      = btrim(p_name),
        emoji     = coalesce(btrim(p_emoji), '🏢'),
        is_active = p_is_active
    where id = p_id
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
  else
    v_code := coalesce(
      btrim(p_code),
      'dept_' || left(replace(gen_random_uuid()::text, '-', ''), 8)
    );
    insert into public.dept_departments (name, code, emoji, sort_order)
    select
      btrim(p_name),
      v_code,
      coalesce(btrim(p_emoji), '🏢'),
      coalesce((select max(sort_order) + 1 from public.dept_departments), 1)
    where not exists (select 1 from public.dept_departments where code = v_code)
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

grant execute on function public.dept_rel_save_department(text, uuid, text, text, text, boolean) to anon;;
