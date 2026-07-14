-- Idarah (mdr_*): per-student document vault for daftar office records.
-- Storage bucket: mdr-student-documents (private, max 500 KB per file).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'mdr-student-documents',
  'mdr-student-documents',
  false,
  512000,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'application/pdf'
  ]::text[]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.mdr_student_documents (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.mdr_students(id) on delete cascade,
  title text not null,
  doc_type text not null default 'other',
  bucket_id text not null default 'mdr-student-documents',
  storage_path text not null,
  file_name text not null default '',
  mime_type text not null default '',
  file_size integer not null default 0 check (file_size > 0 and file_size <= 512000),
  note text not null default '',
  created_by uuid references public.mdr_shared_users(id),
  created_at timestamptz not null default now(),
  constraint mdr_student_documents_doc_type_chk check (
    doc_type in ('student_application', 'guardian_application', 'other')
  ),
  constraint mdr_student_documents_storage_path_uniq unique (storage_path)
);

create index if not exists mdr_student_documents_student_idx
  on public.mdr_student_documents (student_id, created_at desc);

alter table public.mdr_student_documents enable row level security;

drop policy if exists "deny_all_mdr_student_documents" on public.mdr_student_documents;
create policy "deny_all_mdr_student_documents"
  on public.mdr_student_documents for all using (false) with check (false);

drop policy if exists "anon_insert_mdr_student_documents" on storage.objects;
create policy "anon_insert_mdr_student_documents"
  on storage.objects for insert to anon
  with check (bucket_id = 'mdr-student-documents');

drop policy if exists "anon_select_mdr_student_documents" on storage.objects;
create policy "anon_select_mdr_student_documents"
  on storage.objects for select to anon
  using (bucket_id = 'mdr-student-documents');

drop policy if exists "anon_delete_mdr_student_documents" on storage.objects;
create policy "anon_delete_mdr_student_documents"
  on storage.objects for delete to anon
  using (bucket_id = 'mdr-student-documents');

create or replace function private.mdr_student_doc_view_actor(
  p_actor_id uuid,
  p_pin text,
  p_student_id uuid
)
returns public.mdr_shared_users
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_student public.mdr_students%rowtype;
begin
  select *
  into v_actor
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in (
      'admin',
      'restricted_admin',
      'daftar',
      'madrasa_teacher',
      'hifz',
      'library',
      'alumni_tracker',
      'khedmat'
    );

  if v_actor.id is null then
    return null;
  end if;

  select *
  into v_student
  from public.mdr_students
  where id = p_student_id;

  if v_student.id is null then
    return null;
  end if;

  if v_actor.role = 'madrasa_teacher'
     and v_student.current_class_id is distinct from v_actor.class_id then
    return null;
  end if;

  return v_actor;
end;
$$;

create or replace function private.mdr_student_doc_daftar_actor(
  p_actor_id uuid,
  p_pin text
)
returns public.mdr_shared_users
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
begin
  select *
  into v_actor
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role = 'daftar';

  return v_actor;
end;
$$;

create or replace function public.mdr_rel_student_documents_list(
  p_actor_id uuid,
  p_pin text,
  p_student_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
begin
  v_actor := private.mdr_student_doc_view_actor(p_actor_id, p_pin, p_student_id);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  return jsonb_build_object(
    'ok', true,
    'can_manage', v_actor.role = 'daftar',
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id,
        'student_id', d.student_id,
        'title', d.title,
        'doc_type', d.doc_type,
        'bucket_id', d.bucket_id,
        'storage_path', d.storage_path,
        'file_name', d.file_name,
        'mime_type', d.mime_type,
        'file_size', d.file_size,
        'note', d.note,
        'created_at', d.created_at,
        'created_by', coalesce(u.name, '')
      ) order by d.created_at desc)
      from public.mdr_student_documents d
      left join public.mdr_shared_users u on u.id = d.created_by
      where d.student_id = p_student_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.mdr_rel_student_document_add(
  p_actor_id uuid,
  p_pin text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_student public.mdr_students%rowtype;
  v_student_id uuid;
  v_title text;
  v_doc_type text;
  v_path text;
  v_file_name text;
  v_mime_type text;
  v_file_size integer;
  v_note text;
  v_id uuid;
begin
  v_actor := private.mdr_student_doc_daftar_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_payload');
  end if;

  v_student_id := nullif(p_payload->>'studentId', '')::uuid;
  v_title := nullif(btrim(coalesce(p_payload->>'title', '')), '');
  v_doc_type := coalesce(nullif(p_payload->>'docType', ''), 'other');
  v_path := nullif(btrim(coalesce(p_payload->>'storagePath', '')), '');
  v_file_name := coalesce(nullif(p_payload->>'fileName', ''), 'document');
  v_mime_type := coalesce(nullif(p_payload->>'mimeType', ''), 'application/octet-stream');
  v_file_size := greatest(coalesce(nullif(p_payload->>'fileSize', '')::integer, 0), 0);
  v_note := coalesce(p_payload->>'note', '');

  if v_student_id is null or v_title is null or v_path is null then
    return jsonb_build_object('ok', false, 'error', 'required_fields_missing');
  end if;

  if v_doc_type not in ('student_application', 'guardian_application', 'other') then
    return jsonb_build_object('ok', false, 'error', 'invalid_doc_type');
  end if;

  if v_file_size <= 0 or v_file_size > 512000 then
    return jsonb_build_object('ok', false, 'error', 'invalid_file_size');
  end if;

  if v_mime_type not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    return jsonb_build_object('ok', false, 'error', 'invalid_mime_type');
  end if;

  if v_path !~ ('^' || v_student_id::text || '/') then
    return jsonb_build_object('ok', false, 'error', 'invalid_storage_path');
  end if;

  select * into v_student from public.mdr_students where id = v_student_id;
  if v_student.id is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  insert into public.mdr_student_documents (
    student_id, title, doc_type, bucket_id, storage_path,
    file_name, mime_type, file_size, note, created_by
  )
  values (
    v_student_id,
    v_title,
    v_doc_type,
    'mdr-student-documents',
    v_path,
    v_file_name,
    v_mime_type,
    v_file_size,
    v_note,
    v_actor.id
  )
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.mdr_rel_student_document_delete(
  p_actor_id uuid,
  p_pin text,
  p_document_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_path text;
  v_bucket text;
begin
  v_actor := private.mdr_student_doc_daftar_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  delete from public.mdr_student_documents
  where id = p_document_id
  returning storage_path, bucket_id into v_path, v_bucket;

  if v_path is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'storagePath', v_path,
    'bucketId', coalesce(v_bucket, 'mdr-student-documents')
  );
end;
$$;

revoke execute on function private.mdr_student_doc_view_actor(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function private.mdr_student_doc_daftar_actor(uuid, text) from public, anon, authenticated;

revoke execute on function public.mdr_rel_student_documents_list(uuid, text, uuid) from public, authenticated;
revoke execute on function public.mdr_rel_student_document_add(uuid, text, jsonb) from public, authenticated;
revoke execute on function public.mdr_rel_student_document_delete(uuid, text, uuid) from public, authenticated;

grant execute on function public.mdr_rel_student_documents_list(uuid, text, uuid) to anon;
grant execute on function public.mdr_rel_student_document_add(uuid, text, jsonb) to anon;
grant execute on function public.mdr_rel_student_document_delete(uuid, text, uuid) to anon;;
