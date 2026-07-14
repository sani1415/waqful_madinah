-- Hifz is an additional student flag/group membership, not an academic class.

do $$
declare
  v_hifz_class_id uuid;
begin
  select id
  into v_hifz_class_id
  from public.mdr_classes
  where code = 'kitab_hifz'
  limit 1;

  if v_hifz_class_id is not null then
    update public.mdr_students
    set is_hifz = true,
        updated_at = now()
    where current_class_id = v_hifz_class_id;

    update public.shared_users
    set class_id = null
    where class_id = v_hifz_class_id;

    update public.mdr_classes
    set is_active = false
    where id = v_hifz_class_id;
  end if;
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
    'divisions', (
      select coalesce(jsonb_agg(to_jsonb(d) order by d.code), '[]'::jsonb)
      from public.mdr_divisions d
    ),
    'classes', (
      select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order), '[]'::jsonb)
      from public.mdr_classes c
      where c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'student_count', (
      select count(*)
      from public.mdr_students s
      join public.mdr_classes c on c.id = s.current_class_id
      where s.status = 'active'
        and c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'book_count', (
      select count(*)
      from public.mdr_books b
      join public.mdr_classes c on c.id = b.class_id
      where c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'import_pending_count', (
      select count(*)
      from public.mdr_student_import_candidates
      where candidate_status = 'pending'
    )
  );
end;
$$;

grant execute on function public.mdr_rel_admin_bootstrap(text) to anon;

create or replace function public.mdr_rel_admin_students(p_pin text)
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
    'classes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'code', c.code,
        'name', c.name,
        'roll_prefix', c.roll_prefix,
        'sort_order', c.sort_order,
        'division_code', d.code
      ) order by d.code, c.sort_order), '[]'::jsonb)
      from public.mdr_classes c
      join public.mdr_divisions d on d.id = c.division_id
      where c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'students', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id,
        'student_id', s.student_id,
        'name', s.name,
        'guardian_name', s.guardian_name,
        'guardian_phone', s.guardian_phone,
        'district', s.district,
        'upazila', s.upazila,
        'class_code', c.code,
        'class_name', c.name,
        'division_code', d.code,
        'current_roll', s.current_roll,
        'status', s.status,
        'is_hifz', s.is_hifz,
        'special_watch', coalesce(s.special_watch, false),
        'special_watch_at', s.special_watch_at,
        'alhamdulillah', coalesce(s.alhamdulillah, false),
        'alhamdulillah_at', s.alhamdulillah_at
      ) order by d.code, c.sort_order, s.current_roll, s.name), '[]'::jsonb)
      from public.mdr_students s
      join public.mdr_classes c on c.id = s.current_class_id
      join public.mdr_divisions d on d.id = s.division_id
      where s.status = 'active'
        and c.is_active = true
        and c.code <> 'kitab_hifz'
    )
  );
end;
$$;

grant execute on function public.mdr_rel_admin_students(text) to anon;

create or replace function public.mdr_rel_daftar_bootstrap(p_actor_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
begin
  select *
  into v_actor
  from public.shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in ('admin', 'daftar');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  return jsonb_build_object(
    'ok', true,
    'classes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'code', c.code,
        'name', c.name,
        'roll_prefix', c.roll_prefix,
        'sort_order', c.sort_order,
        'division_code', d.code
      ) order by d.code, c.sort_order), '[]'::jsonb)
      from public.mdr_classes c
      join public.mdr_divisions d on d.id = c.division_id
      where c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'students', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id,
        'student_id', s.student_id,
        'name', s.name,
        'guardian_name', s.guardian_name,
        'guardian_phone', s.guardian_phone,
        'district', s.district,
        'upazila', s.upazila,
        'class_code', c.code,
        'class_name', c.name,
        'division_code', d.code,
        'current_roll', s.current_roll,
        'status', s.status,
        'is_hifz', s.is_hifz,
        'special_watch', coalesce(s.special_watch, false),
        'special_watch_at', s.special_watch_at,
        'alhamdulillah', coalesce(s.alhamdulillah, false),
        'alhamdulillah_at', s.alhamdulillah_at
      ) order by d.code, c.sort_order, s.current_roll, s.name), '[]'::jsonb)
      from public.mdr_students s
      join public.mdr_classes c on c.id = s.current_class_id
      join public.mdr_divisions d on d.id = s.division_id
      where s.status = 'active'
        and c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'attendance', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ad.id,
        'student_id', ad.student_id,
        'date', a.date,
        'status', ad.status,
        'absent_reason', ad.absent_reason,
        'hijri_year', ad.hijri_year
      ) order by a.date desc), '[]'::jsonb)
      from public.mdr_attendance_details ad
      join public.mdr_attendance a on a.id = ad.attendance_id
    ),
    'class_teachers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'class_code', c.code,
        'name', u.name
      ) order by d.code, c.sort_order), '[]'::jsonb)
      from public.shared_users u
      join public.mdr_classes c on c.id = u.class_id
      join public.mdr_divisions d on d.id = c.division_id
      where u.role = 'madrasa_teacher'
        and u.is_active = true
        and c.is_active = true
        and c.code <> 'kitab_hifz'
    )
  );
end;
$$;

grant execute on function public.mdr_rel_daftar_bootstrap(uuid, text) to anon;

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
    and c.is_active = true
    and c.code <> 'kitab_hifz';

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
  values (v_student_id, v_class_id, trim(p_roll), current_date, 'পুরোনো ব্যাকআপ থেকে অনুমোদিত');

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

grant execute on function public.mdr_rel_approve_import_candidate(text, uuid, text, text, text, text) to anon;;
