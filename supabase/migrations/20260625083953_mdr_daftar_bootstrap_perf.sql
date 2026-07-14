-- daftar bootstrap: ~68k attendance rows → ~10MB JSON → statement timeout (500)
-- Fix: attendance_dates (distinct days) + recent 30-day row window; per-day fetch RPC

create or replace function public.mdr_rel_daftar_attendance_for_date(
  p_actor_id uuid,
  p_pin text,
  p_date date
)
returns jsonb
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
    and role in ('admin', 'daftar');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  if p_date is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_date');
  end if;

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
  v_recent_start date;
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

  v_recent_start := greatest(v_session_start, (current_date - interval '30 days')::date);

  return jsonb_build_object(
    'ok', true,
    'session_start_date', v_session_start,
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
      join public.mdr_divisions d on d.id = c.division_id
      where s.status = 'active'
        and c.is_active = true
        and c.code <> 'kitab_hifz'
    ),
    'attendance_dates', (
      select coalesce(jsonb_agg(d.date order by d.date), '[]'::jsonb)
      from (
        select distinct a.date
        from public.mdr_attendance a
        where a.date >= v_session_start
          and a.date <= current_date
      ) d
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
      where a.date >= v_recent_start
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

revoke execute on function public.mdr_rel_daftar_attendance_for_date(uuid, text, date) from public, authenticated;
grant execute on function public.mdr_rel_daftar_attendance_for_date(uuid, text, date) to anon;;
