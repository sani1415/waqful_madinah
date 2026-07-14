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
  for delete to anon using (bucket_id = 'waqf-files');;
