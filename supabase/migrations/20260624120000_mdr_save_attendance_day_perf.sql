-- হাজিরা সেভ: per-student লুপ + সব ইতিহাস return → statement timeout (57014)
-- Fix: class-wise header + bulk upsert; শুধু সেভ করা দিন return
-- Bootstrap: শুধু session_start_date → আজ (পুরো ইতিহাস নয়)
-- Live DB: shared_users → mdr_shared_users (Idarah prefix rename)

create or replace function public.mdr_rel_save_attendance_day(
  p_actor_id uuid,
  p_pin text,
  p_date date,
  p_records jsonb,
  p_hijri_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_class_id uuid;
  v_incoming_count int;
  v_joined_count int;
begin
  select *
  into v_actor
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in ('admin', 'daftar');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  if p_date is null or p_records is null or jsonb_typeof(p_records) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'invalid_payload');
  end if;

  select count(*)
  into v_incoming_count
  from jsonb_to_recordset(p_records) as r(student_id uuid, status text, absent_reason text);

  if v_incoming_count = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty_payload');
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_records) as r(student_id uuid, status text, absent_reason text)
    where r.status not in ('present', 'absent', 'holiday')
  ) then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;

  select count(*)
  into v_joined_count
  from jsonb_to_recordset(p_records) as r(student_id uuid, status text, absent_reason text)
  join public.mdr_students s on s.id = r.student_id and s.status = 'active';

  if v_joined_count <> v_incoming_count then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  for v_class_id in
    select distinct s.current_class_id
    from jsonb_to_recordset(p_records) as r(student_id uuid, status text, absent_reason text)
    join public.mdr_students s on s.id = r.student_id
    where s.current_class_id is not null
  loop
    insert into public.mdr_attendance (class_id, date, entered_by)
    values (v_class_id, p_date, v_actor.id)
    on conflict (class_id, date)
    do update set entered_by = excluded.entered_by;
  end loop;

  insert into public.mdr_attendance_details (
    attendance_id, student_id, status, absent_reason, hijri_year, updated_at
  )
  select
    a.id,
    r.student_id,
    r.status,
    case
      when r.status = 'absent' then nullif(btrim(coalesce(r.absent_reason, '')), '')
      else null
    end,
    nullif(btrim(coalesce(p_hijri_year, '')), ''),
    now()
  from jsonb_to_recordset(p_records) as r(student_id uuid, status text, absent_reason text)
  join public.mdr_students s on s.id = r.student_id and s.status = 'active'
  join public.mdr_attendance a on a.class_id = s.current_class_id and a.date = p_date
  on conflict (attendance_id, student_id)
  do update set
    status = excluded.status,
    absent_reason = excluded.absent_reason,
    hijri_year = excluded.hijri_year,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'date', p_date,
    'attendance', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ad.id,
        'student_id', ad.student_id,
        'date', a.date,
        'status', ad.status,
        'absent_reason', ad.absent_reason,
        'hijri_year', ad.hijri_year
      ) order by s.current_roll nulls last, s.name), '[]'::jsonb)
      from public.mdr_attendance_details ad
      join public.mdr_attendance a on a.id = ad.attendance_id
      join public.mdr_students s on s.id = ad.student_id
      where a.date = p_date
    )
  );
end;
$$;
create or replace function public.mdr_rel_daftar_bootstrap(p_actor_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_session_start date;
begin
  select *
  into v_actor
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in ('admin', 'daftar');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  select s.session_start_date
  into v_session_start
  from public.mdr_settings s
  where s.id = true;

  if v_session_start is null then
    v_session_start := (current_date - interval '120 days')::date;
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
      where a.date >= v_session_start
        and a.date <= current_date
    ),
    'class_teachers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'class_code', c.code,
        'name', u.name
      ) order by d.code, c.sort_order), '[]'::jsonb)
      from public.mdr_shared_users u
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
grant execute on function public.mdr_rel_save_attendance_day(uuid, text, date, jsonb, text) to anon;
grant execute on function public.mdr_rel_daftar_bootstrap(uuid, text) to anon;
