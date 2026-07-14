alter table public.mdr_divisions enable row level security;
alter table public.mdr_classes enable row level security;
alter table public.mdr_students enable row level security;
alter table public.mdr_class_history enable row level security;
alter table public.mdr_books enable row level security;
alter table public.mdr_book_progress enable row level security;
alter table public.mdr_student_import_candidates enable row level security;

drop policy if exists "deny_all_mdr_divisions" on public.mdr_divisions;
create policy "deny_all_mdr_divisions" on public.mdr_divisions for all using (false) with check (false);

drop policy if exists "deny_all_mdr_classes" on public.mdr_classes;
create policy "deny_all_mdr_classes" on public.mdr_classes for all using (false) with check (false);

drop policy if exists "deny_all_mdr_students" on public.mdr_students;
create policy "deny_all_mdr_students" on public.mdr_students for all using (false) with check (false);

drop policy if exists "deny_all_mdr_class_history" on public.mdr_class_history;
create policy "deny_all_mdr_class_history" on public.mdr_class_history for all using (false) with check (false);

drop policy if exists "deny_all_mdr_books" on public.mdr_books;
create policy "deny_all_mdr_books" on public.mdr_books for all using (false) with check (false);

drop policy if exists "deny_all_mdr_book_progress" on public.mdr_book_progress;
create policy "deny_all_mdr_book_progress" on public.mdr_book_progress for all using (false) with check (false);

drop policy if exists "deny_all_mdr_student_import_candidates" on public.mdr_student_import_candidates;
create policy "deny_all_mdr_student_import_candidates" on public.mdr_student_import_candidates for all using (false) with check (false);

create or replace function public.mdr_rel_admin_login(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_user public.shared_users%rowtype;
begin
  select *
  into v_user
  from public.shared_users
  where role = 'admin'
    and is_active = true
    and pin = p_pin
  order by created_at
  limit 1;

  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  return jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', v_user.id,
      'name', v_user.name,
      'role', v_user.role,
      'module_access', v_user.module_access,
      'admin_perms', v_user.admin_perms
    )
  );
end;
$$;

create or replace function public.mdr_rel_user_login(p_user_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_user public.shared_users%rowtype;
begin
  select *
  into v_user
  from public.shared_users
  where id = p_user_id
    and is_active = true
    and pin = p_pin;

  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_user_or_pin');
  end if;

  return jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', v_user.id,
      'name', v_user.name,
      'role', v_user.role,
      'module_access', v_user.module_access,
      'admin_perms', v_user.admin_perms,
      'class_id', v_user.class_id,
      'dept_code', v_user.dept_code
    )
  );
end;
$$;

create or replace function public.mdr_rel_admin_bootstrap(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  return jsonb_build_object(
    'ok', true,
    'divisions', (select coalesce(jsonb_agg(to_jsonb(d) order by d.code), '[]'::jsonb) from public.mdr_divisions d),
    'classes', (select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order), '[]'::jsonb) from public.mdr_classes c),
    'student_count', (select count(*) from public.mdr_students),
    'import_pending_count', (
      select count(*)
      from public.mdr_student_import_candidates
      where candidate_status = 'pending'
    )
  );
end;
$$;

create or replace function public.mdr_rel_import_candidates(p_pin text, p_source text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  return jsonb_build_object(
    'ok', true,
    'items', (
      select coalesce(jsonb_agg(to_jsonb(c) order by c.source, c.class_code, c.old_roll), '[]'::jsonb)
      from public.mdr_student_import_candidates c
      where c.candidate_status = 'pending'
        and (p_source is null or c.source = p_source)
    )
  );
end;
$$;

create or replace function public.mdr_rel_approve_import_candidate(
  p_pin text,
  p_candidate_id uuid,
  p_student_id text,
  p_class_code text,
  p_roll text,
  p_hijri_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_candidate public.mdr_student_import_candidates%rowtype;
  v_division_id uuid;
  v_class_id uuid;
  v_student_id uuid;
begin
  if not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  select * into v_candidate
  from public.mdr_student_import_candidates
  where id = p_candidate_id
    and candidate_status = 'pending';

  if v_candidate.id is null then
    return jsonb_build_object('ok', false, 'error', 'candidate_not_found');
  end if;

  select c.id, c.division_id
  into v_class_id, v_division_id
  from public.mdr_classes c
  where c.code = p_class_code
    and c.is_active = true;

  if v_class_id is null then
    return jsonb_build_object('ok', false, 'error', 'class_not_found');
  end if;

  insert into public.mdr_students (
    student_id,
    name,
    guardian_name,
    guardian_phone,
    district,
    upazila,
    division_id,
    current_class_id,
    current_roll,
    admission_date,
    hijri_year,
    status,
    is_hifz,
    import_source,
    old_student_id
  )
  values (
    trim(p_student_id),
    v_candidate.name,
    v_candidate.guardian_name,
    v_candidate.guardian_phone,
    v_candidate.district,
    v_candidate.upazila,
    v_division_id,
    v_class_id,
    trim(p_roll),
    current_date,
    nullif(trim(coalesce(p_hijri_year, '')), ''),
    'active',
    v_candidate.suggested_is_hifz,
    v_candidate.source,
    v_candidate.old_student_id
  )
  returning id into v_student_id;

  insert into public.mdr_class_history (student_id, class_id, roll, from_date, notes)
  values (v_student_id, v_class_id, trim(p_roll), current_date, 'পুরনো ব্যাকআপ থেকে অনুমোদিত');

  update public.mdr_student_import_candidates
  set candidate_status = 'approved',
      approved_student_id = v_student_id
  where id = p_candidate_id;

  return jsonb_build_object('ok', true, 'student_uuid', v_student_id);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'student_id_already_exists');
end;
$$;

grant execute on function public.mdr_rel_admin_login(text) to anon;
grant execute on function public.mdr_rel_user_login(uuid, text) to anon;
grant execute on function public.mdr_rel_admin_bootstrap(text) to anon;
grant execute on function public.mdr_rel_import_candidates(text, text) to anon;
grant execute on function public.mdr_rel_approve_import_candidate(text, uuid, text, text, text, text) to anon;;
