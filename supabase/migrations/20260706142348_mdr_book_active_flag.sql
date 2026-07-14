-- কিতাব "সক্রিয়/নিষ্ক্রিয়" ফ্ল্যাগ: বর্ষ দায়িত্বশীল ঠিক করবে কোন বই এখন পড়ানো হচ্ছে,
-- আর ৭-দিনের কিতাব-ডিউটি লক শুধু সক্রিয় বইগুলোর ওপর নির্ভর করবে।

alter table public.mdr_books
  add column if not exists is_active boolean not null default true;

-- ── শিক্ষক নিজের ক্লাসের বইয়ে active/inactive টগল করবে ──
create or replace function public.mdr_rel_set_book_active(
  p_actor_id uuid,
  p_pin text,
  p_book_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_book public.mdr_books%rowtype;
begin
  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_teacher'); end if;

  select * into v_book from public.mdr_books where id = p_book_id;
  if v_book.id is null then return jsonb_build_object('ok', false, 'error', 'book_not_found'); end if;
  if v_book.class_id <> v_actor.class_id then return jsonb_build_object('ok', false, 'error', 'not_teacher_class'); end if;

  update public.mdr_books set is_active = coalesce(p_is_active, true) where id = p_book_id;

  return jsonb_build_object('ok', true, 'id', p_book_id);
end;
$$;

grant execute on function public.mdr_rel_set_book_active(uuid, text, uuid, boolean) to anon;

-- ── bootstrap-দুটোর books sub-select-এ is_active যোগ ──
create or replace function public.mdr_rel_teacher_class_bootstrap(p_actor_id uuid, p_pin text)
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
    and role = 'madrasa_teacher'
    and class_id is not null;

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  return jsonb_build_object(
    'ok', true,
    'students', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'student_id', s.student_id, 'name', s.name, 'guardian_name', s.guardian_name,
        'guardian_phone', s.guardian_phone, 'district', s.district, 'upazila', s.upazila,
        'class_code', c.code, 'class_name', c.name, 'division_code', d.code,
        'current_roll', s.current_roll, 'status', s.status, 'is_hifz', s.is_hifz,
        'special_watch', coalesce(s.special_watch, false),
        'special_watch_at', s.special_watch_at,
        'alhamdulillah', coalesce(s.alhamdulillah, false),
        'alhamdulillah_at', s.alhamdulillah_at
      ) order by s.current_roll, s.name), '[]'::jsonb)
      from public.mdr_students s
      join public.mdr_classes c on c.id = s.current_class_id
      join public.mdr_divisions d on d.id = s.division_id
      where s.status = 'active'
        and s.current_class_id = v_actor.class_id
    ),
    'books', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'class_code', c.code, 'class_name', c.name,
        'total_pages', b.total_pages, 'sort_order', b.sort_order,
        'is_active', coalesce(b.is_active, true),
        'pages_done', coalesce(bp.pages_done, 0), 'notes', bp.notes, 'updated_at', bp.updated_at
      ) order by b.sort_order, b.name), '[]'::jsonb)
      from public.mdr_books b
      join public.mdr_classes c on c.id = b.class_id
      left join public.mdr_book_progress bp on bp.book_id = b.id
      where b.class_id = v_actor.class_id
    ),
    'book_progress_history', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id,
        'book_id', e.book_id,
        'class_code', c.code,
        'pages_done', e.pages_done,
        'note', e.notes,
        'date', e.created_at::date,
        'by', coalesce(u.name, '')
      ) order by e.created_at desc), '[]'::jsonb)
      from public.mdr_book_progress_events e
      join public.mdr_classes c on c.id = e.class_id
      left join public.mdr_shared_users u on u.id = e.updated_by
      where e.class_id = v_actor.class_id
    ),
    'akhlaq', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id,
        'student_id', a.student_id,
        'score', a.score,
        'reason', a.reason,
        'date', a.evaluated_at::date,
        'at', a.evaluated_at,
        'by', coalesce(u.name, '')
      ) order by a.evaluated_at desc), '[]'::jsonb)
      from public.mdr_akhlaq a
      join public.mdr_students s on s.id = a.student_id
      left join public.mdr_shared_users u on u.id = a.evaluated_by
      where s.current_class_id = v_actor.class_id
    ),
    'logs', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id,
        'type', l.type,
        'class_code', c.code,
        'student_id', l.student_id,
        'content', l.content,
        'date', l.created_at::date,
        'by', coalesce(u.name, ''),
        'review_requested', l.review_requested,
        'reviewed_at', l.reviewed_at,
        'reviewed_by_name', coalesce(ru.name, ''),
        'admin_reply', l.admin_reply
      ) order by l.created_at desc), '[]'::jsonb)
      from public.mdr_logs l
      left join public.mdr_students s on s.id = l.student_id
      left join public.mdr_classes c on c.id = coalesce(l.class_id, s.current_class_id)
      left join public.mdr_shared_users u on u.id = l.written_by
      left join public.mdr_shared_users ru on ru.id = l.reviewed_by
      where coalesce(l.class_id, s.current_class_id) = v_actor.class_id
    )
  );
end;
$$;

create or replace function public.mdr_rel_admin_madrasa_bootstrap(
  p_actor_id uuid,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_depts text[];
  v_session_start date;
  v_recent_start date;
begin
  v_actor := private.mdr_admin_dashboard_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  if v_actor.role = 'admin' or coalesce(v_actor.admin_perms->>'super_admin', 'false') = 'true' then
    v_depts := array['kitab','maktab']::text[];
  else
    select array(
      select value
      from jsonb_array_elements_text(coalesce(v_actor.admin_perms->'scope'->'madrasa_depts', '[]'::jsonb)) as t(value)
      where value in ('kitab', 'maktab')
    ) into v_depts;
  end if;

  select s.session_start_date
  into v_session_start
  from public.mdr_settings s
  where s.id = true;

  if v_session_start is null then
    v_session_start := (current_date - interval '120 days')::date;
  end if;

  v_recent_start := greatest(v_session_start, (current_date - interval '30 days')::date);

  if coalesce(array_length(v_depts, 1), 0) = 0 then
    return jsonb_build_object(
      'ok', true,
      'session_start_date', v_session_start,
      'classes', '[]'::jsonb,
      'students', '[]'::jsonb,
      'attendance_dates', '[]'::jsonb,
      'attendance', '[]'::jsonb,
      'books', '[]'::jsonb,
      'book_progress_history', '[]'::jsonb,
      'akhlaq', '[]'::jsonb,
      'logs', '[]'::jsonb
    );
  end if;

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
      ) order by d.code, c.sort_order, c.name), '[]'::jsonb)
      from public.mdr_classes c
      join public.mdr_divisions d on d.id = c.division_id
      where c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
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
        and d.code = any(v_depts)
    ),
    'attendance_dates', (
      select coalesce(jsonb_agg(distinct_dates.d order by distinct_dates.d), '[]'::jsonb)
      from (
        select distinct a.date as d
        from public.mdr_attendance a
        join public.mdr_classes c on c.id = a.class_id
        join public.mdr_divisions d on d.id = c.division_id
        where a.date >= v_session_start
          and a.date <= current_date
          and c.is_active = true
          and c.code <> 'kitab_hifz'
          and d.code = any(v_depts)
      ) distinct_dates
    ),
    'attendance', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ad.id,
        'student_id', ad.student_id,
        'date', a.date,
        'status', ad.status,
        'absent_reason', ad.absent_reason,
        'hijri_year', ad.hijri_year
      ) order by a.date desc, ad.updated_at desc), '[]'::jsonb)
      from public.mdr_attendance_details ad
      join public.mdr_attendance a on a.id = ad.attendance_id
      join public.mdr_classes c on c.id = a.class_id
      join public.mdr_divisions d on d.id = c.division_id
      where c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
        and a.date >= v_recent_start
        and a.date <= current_date
    ),
    'books', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id,
        'name', b.name,
        'class_code', c.code,
        'class_name', c.name,
        'division_code', d.code,
        'total_pages', b.total_pages,
        'sort_order', b.sort_order,
        'is_active', coalesce(b.is_active, true),
        'pages_done', coalesce(bp.pages_done, 0),
        'notes', bp.notes,
        'updated_at', bp.updated_at
      ) order by d.code, c.sort_order, b.sort_order, b.name), '[]'::jsonb)
      from public.mdr_books b
      join public.mdr_classes c on c.id = b.class_id
      join public.mdr_divisions d on d.id = c.division_id
      left join public.mdr_book_progress bp on bp.book_id = b.id
      where c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
    ),
    'book_progress_history', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id,
        'book_id', e.book_id,
        'class_code', c.code,
        'division_code', d.code,
        'pages_done', e.pages_done,
        'note', e.notes,
        'date', e.created_at::date,
        'by', coalesce(u.name, '')
      ) order by e.created_at desc), '[]'::jsonb)
      from public.mdr_book_progress_events e
      join public.mdr_classes c on c.id = e.class_id
      join public.mdr_divisions d on d.id = c.division_id
      left join public.mdr_shared_users u on u.id = e.updated_by
      where c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
    ),
    'akhlaq', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id,
        'student_id', a.student_id,
        'score', a.score,
        'reason', a.reason,
        'date', a.evaluated_at::date,
        'at', a.evaluated_at,
        'by', coalesce(u.name, '')
      ) order by a.evaluated_at desc), '[]'::jsonb)
      from public.mdr_akhlaq a
      join public.mdr_students s on s.id = a.student_id
      join public.mdr_classes c on c.id = s.current_class_id
      join public.mdr_divisions d on d.id = c.division_id
      left join public.mdr_shared_users u on u.id = a.evaluated_by
      where s.status = 'active'
        and c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
    ),
    'logs', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id,
        'type', l.type,
        'class_code', c.code,
        'student_id', l.student_id,
        'content', l.content,
        'date', l.created_at::date,
        'by', coalesce(u.name, ''),
        'review_requested', l.review_requested,
        'reviewed_at', l.reviewed_at,
        'reviewed_by_name', coalesce(ru.name, ''),
        'admin_reply', l.admin_reply
      ) order by l.created_at desc), '[]'::jsonb)
      from public.mdr_logs l
      left join public.mdr_students s on s.id = l.student_id
      join public.mdr_classes c on c.id = coalesce(l.class_id, s.current_class_id)
      join public.mdr_divisions d on d.id = c.division_id
      left join public.mdr_shared_users u on u.id = l.written_by
      left join public.mdr_shared_users ru on ru.id = l.reviewed_by
      where c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
    )
  );
end;
$$;;
