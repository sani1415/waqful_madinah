-- শিক্ষক-লগ রিভিউ ওয়ার্কফ্লো: class লগ + review-tagged student লগ → admin pending queue।
-- admin "ডান করুন" অথবা reply দিয়ে resolve করতে পারবে। Push notification-ও যোগ হলো।

alter table public.mdr_logs
  add column if not exists review_requested boolean not null default false,
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references public.mdr_shared_users(id),
  add column if not exists admin_reply text;

-- Backfill: পুরনো সব লগ "already reviewed" ধরে নেওয়া হলো, শুধু আজকের পর যোগ হওয়া লগ-ই queue-তে ঢুকবে।
update public.mdr_logs set reviewed_at = created_at where reviewed_at is null;

-- ── mdr_rel_save_teacher_log: signature বদলাচ্ছে (নতুন প্যারামিটার), তাই আগে পুরনো overload ড্রপ ──
drop function if exists public.mdr_rel_save_teacher_log(uuid, text, text, uuid, text);

create or replace function public.mdr_rel_save_teacher_log(
  p_actor_id uuid,
  p_pin text,
  p_type text,
  p_student_id uuid,
  p_content text,
  p_review_requested boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_admin_actor public.mdr_shared_users%rowtype;
  v_student public.mdr_students%rowtype;
  v_is_admin boolean := false;
  v_division_code text;
  v_id uuid;
begin
  if p_type not in ('class', 'student') then
    return jsonb_build_object('ok', false, 'error', 'invalid_type');
  end if;
  if btrim(coalesce(p_content, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'content_required');
  end if;

  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin and role = 'madrasa_teacher' and class_id is not null;

  if v_actor.id is null then
    v_admin_actor := private.mdr_admin_dashboard_actor(p_actor_id, p_pin);
    if v_admin_actor.id is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
    end if;
    v_actor := v_admin_actor;
    v_is_admin := true;
  end if;

  if p_type = 'student' then
    select * into v_student from public.mdr_students where id = p_student_id and status = 'active';
    if v_student.id is null then return jsonb_build_object('ok', false, 'error', 'student_not_found'); end if;

    if v_is_admin then
      if v_actor.role = 'restricted_admin' and coalesce(v_actor.admin_perms->>'super_admin', 'false') <> 'true' then
        select d.code into v_division_code
        from public.mdr_classes c
        join public.mdr_divisions d on d.id = c.division_id
        where c.id = v_student.current_class_id;

        if v_division_code is null or not (v_division_code = any(
          select value from jsonb_array_elements_text(coalesce(v_actor.admin_perms->'scope'->'madrasa_depts', '[]'::jsonb)) t(value)
        )) then
          return jsonb_build_object('ok', false, 'error', 'not_allowed');
        end if;
      end if;
    else
      if v_student.current_class_id <> v_actor.class_id then
        return jsonb_build_object('ok', false, 'error', 'not_teacher_class');
      end if;
    end if;

    insert into public.mdr_logs (type, student_id, content, written_by, review_requested)
    values ('student', p_student_id, btrim(p_content), v_actor.id, coalesce(p_review_requested, false))
    returning id into v_id;
  else
    if v_is_admin then
      return jsonb_build_object('ok', false, 'error', 'admin_class_log_not_supported');
    end if;
    insert into public.mdr_logs (type, class_id, content, written_by, review_requested)
    values ('class', v_actor.class_id, btrim(p_content), v_actor.id, true)
    returning id into v_id;
  end if;

  insert into public.mdr_shared_notifications (target, title, body, source_type, source_id)
  values ('admin', case when p_type = 'student' then 'নতুন ছাত্র লগ' else 'নতুন বর্ষ লগ' end, btrim(p_content), 'log', v_id);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

grant execute on function public.mdr_rel_save_teacher_log(uuid, text, text, uuid, text, boolean) to anon;

-- ── নতুন RPC: admin একটা pending log resolve করবে (reply সহ বা ছাড়া) ──
create or replace function public.mdr_rel_admin_review_log(
  p_actor_id uuid,
  p_pin text,
  p_log_id uuid,
  p_reply text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_row record;
  v_division_code text;
begin
  v_actor := private.mdr_admin_dashboard_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  select l.id, l.reviewed_at, coalesce(l.class_id, s.current_class_id) as scope_class_id
  into v_row
  from public.mdr_logs l
  left join public.mdr_students s on s.id = l.student_id
  where l.id = p_log_id;

  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'log_not_found');
  end if;
  if v_row.reviewed_at is not null then
    return jsonb_build_object('ok', false, 'error', 'already_reviewed');
  end if;

  if v_actor.role = 'restricted_admin' and coalesce(v_actor.admin_perms->>'super_admin', 'false') <> 'true' then
    select d.code into v_division_code
    from public.mdr_classes c
    join public.mdr_divisions d on d.id = c.division_id
    where c.id = v_row.scope_class_id;

    if v_division_code is null or not (v_division_code = any(
      select value from jsonb_array_elements_text(coalesce(v_actor.admin_perms->'scope'->'madrasa_depts', '[]'::jsonb)) t(value)
    )) then
      return jsonb_build_object('ok', false, 'error', 'not_allowed');
    end if;
  end if;

  update public.mdr_logs
  set reviewed_at = now(),
      reviewed_by = v_actor.id,
      admin_reply = nullif(btrim(coalesce(p_reply, '')), '')
  where id = p_log_id;

  return jsonb_build_object('ok', true, 'id', p_log_id);
end;
$$;

grant execute on function public.mdr_rel_admin_review_log(uuid, text, uuid, text) to anon;

-- ── নতুন RPC: টপবার ব্যাজের জন্য হালকা pending-count ──
create or replace function public.mdr_rel_admin_pending_review_count(
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
  v_log_count integer := 0;
  v_tag_count integer := 0;
begin
  v_actor := private.mdr_admin_dashboard_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  if v_actor.role = 'admin' or coalesce(v_actor.admin_perms->>'super_admin', 'false') = 'true' then
    v_depts := array['kitab', 'maktab']::text[];
  else
    select array(
      select value
      from jsonb_array_elements_text(coalesce(v_actor.admin_perms->'scope'->'madrasa_depts', '[]'::jsonb)) t(value)
      where value in ('kitab', 'maktab')
    ) into v_depts;
  end if;

  if coalesce(array_length(v_depts, 1), 0) > 0 then
    select count(*) into v_log_count
    from public.mdr_logs l
    left join public.mdr_students s on s.id = l.student_id
    join public.mdr_classes c on c.id = coalesce(l.class_id, s.current_class_id)
    join public.mdr_divisions d on d.id = c.division_id
    where l.reviewed_at is null
      and (l.type = 'class' or l.review_requested = true)
      and d.code = any(v_depts);
  end if;

  select count(*) into v_tag_count
  from public.mdr_shared_messages m
  where m.request is not null
    and m.request->>'kind' = 'student_tag'
    and coalesce(m.request->>'status', 'pending') = 'pending';

  return jsonb_build_object('ok', true, 'count', v_log_count + v_tag_count, 'log_count', v_log_count, 'tag_count', v_tag_count);
end;
$$;

grant execute on function public.mdr_rel_admin_pending_review_count(uuid, text) to anon;

-- ── Bootstrap RPC-গুলোর logs sub-select-এ review/reply ফিল্ড যোগ ──
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
$$;

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
        'special_watch_at', s.special_watch_at
      ) order by s.current_roll, s.name), '[]'::jsonb)
      from public.mdr_students s
      join public.mdr_classes c on c.id = s.current_class_id
      join public.mdr_divisions d on d.id = s.division_id
      where s.status = 'active'
        and s.current_class_id = v_actor.class_id
    ),
    'books', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id,
        'name', b.name,
        'class_code', c.code,
        'class_name', c.name,
        'total_pages', b.total_pages,
        'sort_order', b.sort_order,
        'pages_done', coalesce(bp.pages_done, 0),
        'notes', bp.notes,
        'updated_at', bp.updated_at
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

-- ── Push trigger: chat message payload-এ id/request যোগ ──
create or replace function private.mdr_notify_admin_new_message()
returns trigger
language plpgsql
security definer
set search_path = public, vault, extensions
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets
    where name = 'mdr_notify_webhook_secret'
    limit 1;

  perform net.http_post(
    url := 'https://bbdtoucanihtrymzpynq.supabase.co/functions/v1/send-admin-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-notify-secret', coalesce(v_secret, '')
    ),
    body := jsonb_build_object(
      'from_role', NEW.from_role,
      'from_name', NEW.from_name,
      'body', NEW.body,
      'thread_id', NEW.thread_id,
      'message_id', NEW.id,
      'request', NEW.request
    ),
    timeout_milliseconds := 5000
  );

  return NEW;
end;
$$;

-- ── নতুন trigger: mdr_logs-এ class/review-tagged insert হলে admin-কে push ──
create or replace function private.mdr_notify_admin_new_log()
returns trigger
language plpgsql
security definer
set search_path = public, vault, extensions
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets
    where name = 'mdr_notify_webhook_secret'
    limit 1;

  perform net.http_post(
    url := 'https://bbdtoucanihtrymzpynq.supabase.co/functions/v1/send-admin-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-notify-secret', coalesce(v_secret, '')
    ),
    body := jsonb_build_object(
      'kind', 'log_review',
      'log_type', NEW.type,
      'log_id', NEW.id
    ),
    timeout_milliseconds := 5000
  );

  return NEW;
end;
$$;

revoke all on function private.mdr_notify_admin_new_log() from public, anon, authenticated;

drop trigger if exists mdr_logs_notify_admin on public.mdr_logs;
create trigger mdr_logs_notify_admin
  after insert on public.mdr_logs
  for each row
  when (NEW.type = 'class' or NEW.review_requested = true)
  execute function private.mdr_notify_admin_new_log();
;
