-- 022_mdr_teacher_chat_notifications.sql
-- Teacher class records, admin/staff chat, and lightweight notifications.
-- Existing Waqf app tables are intentionally untouched.

create table if not exists public.mdr_akhlaq (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.mdr_students(id) on delete cascade,
  score integer not null check (score between 0 and 100),
  reason text not null,
  evaluated_by uuid references public.shared_users(id),
  evaluated_at timestamptz not null default now()
);

create table if not exists public.mdr_logs (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('class', 'student')),
  class_id uuid references public.mdr_classes(id) on delete cascade,
  student_id uuid references public.mdr_students(id) on delete cascade,
  content text not null,
  written_by uuid references public.shared_users(id),
  created_at timestamptz not null default now(),
  constraint mdr_logs_ref_check check (
    (type = 'class' and class_id is not null and student_id is null) or
    (type = 'student' and student_id is not null)
  )
);

create table if not exists public.mdr_book_progress_events (
  id uuid primary key default gen_random_uuid(),
  book_id uuid not null references public.mdr_books(id) on delete cascade,
  class_id uuid not null references public.mdr_classes(id) on delete cascade,
  pages_done integer not null default 0 check (pages_done >= 0),
  notes text,
  updated_by uuid references public.shared_users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.shared_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id text not null,
  from_user_id uuid references public.shared_users(id) on delete set null,
  from_role text not null,
  from_name text not null,
  body text not null,
  read_admin boolean not null default false,
  read_staff boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.shared_notifications (
  id uuid primary key default gen_random_uuid(),
  target text not null,
  title text not null,
  body text,
  source_type text not null,
  source_id uuid,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.mdr_akhlaq enable row level security;
alter table public.mdr_logs enable row level security;
alter table public.mdr_book_progress_events enable row level security;
alter table public.shared_messages enable row level security;
alter table public.shared_notifications enable row level security;

drop policy if exists "deny_all_mdr_akhlaq" on public.mdr_akhlaq;
create policy "deny_all_mdr_akhlaq" on public.mdr_akhlaq for all using (false) with check (false);

drop policy if exists "deny_all_mdr_logs" on public.mdr_logs;
create policy "deny_all_mdr_logs" on public.mdr_logs for all using (false) with check (false);

drop policy if exists "deny_all_mdr_book_progress_events" on public.mdr_book_progress_events;
create policy "deny_all_mdr_book_progress_events" on public.mdr_book_progress_events for all using (false) with check (false);

drop policy if exists "deny_all_shared_messages" on public.shared_messages;
create policy "deny_all_shared_messages" on public.shared_messages for all using (false) with check (false);

drop policy if exists "deny_all_shared_notifications" on public.shared_notifications;
create policy "deny_all_shared_notifications" on public.shared_notifications for all using (false) with check (false);

create index if not exists idx_mdr_akhlaq_student_time on public.mdr_akhlaq(student_id, evaluated_at desc);
create index if not exists idx_mdr_logs_class_time on public.mdr_logs(class_id, created_at desc);
create index if not exists idx_mdr_logs_student_time on public.mdr_logs(student_id, created_at desc);
create index if not exists idx_mdr_book_progress_events_book_time on public.mdr_book_progress_events(book_id, created_at desc);
create index if not exists idx_shared_messages_thread_time on public.shared_messages(thread_id, created_at);
create index if not exists idx_shared_messages_unread_admin on public.shared_messages(read_admin) where read_admin = false;
create index if not exists idx_shared_messages_unread_staff on public.shared_messages(thread_id, read_staff) where read_staff = false;

create or replace function private.mdr_actor_thread(v_actor public.shared_users)
returns text
language plpgsql
stable
as $$
begin
  return case
    when v_actor.role = 'madrasa_teacher' then 'teacher-' || v_actor.id::text
    when v_actor.role = 'alumni_tracker' then 'alumni'
    when v_actor.role = 'dept_head' then 'dept-' || coalesce(v_actor.dept_code, v_actor.id::text)
    else v_actor.role
  end;
end;
$$;

create or replace function public.mdr_rel_teacher_class_bootstrap(p_actor_id uuid, p_pin text)
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
      left join public.shared_users u on u.id = e.updated_by
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
      left join public.shared_users u on u.id = a.evaluated_by
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
        'by', coalesce(u.name, '')
      ) order by l.created_at desc), '[]'::jsonb)
      from public.mdr_logs l
      left join public.mdr_students s on s.id = l.student_id
      left join public.mdr_classes c on c.id = coalesce(l.class_id, s.current_class_id)
      left join public.shared_users u on u.id = l.written_by
      where coalesce(l.class_id, s.current_class_id) = v_actor.class_id
    )
  );
end;
$$;

create or replace function public.mdr_rel_save_akhlaq(
  p_actor_id uuid,
  p_pin text,
  p_student_id uuid,
  p_score integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_student public.mdr_students%rowtype;
  v_id uuid;
begin
  select * into v_actor from public.shared_users
  where id = p_actor_id and is_active = true and pin = p_pin and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_teacher'); end if;
  if p_score is null or p_score < 0 or p_score > 100 then return jsonb_build_object('ok', false, 'error', 'invalid_score'); end if;
  if btrim(coalesce(p_reason, '')) = '' then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;

  select * into v_student from public.mdr_students where id = p_student_id and status = 'active';
  if v_student.id is null then return jsonb_build_object('ok', false, 'error', 'student_not_found'); end if;
  if v_student.current_class_id <> v_actor.class_id then return jsonb_build_object('ok', false, 'error', 'not_teacher_class'); end if;

  insert into public.mdr_akhlaq (student_id, score, reason, evaluated_by)
  values (p_student_id, p_score, btrim(p_reason), v_actor.id)
  returning id into v_id;

  insert into public.shared_notifications (target, title, body, source_type, source_id)
  values ('admin', 'নতুন হুসনুল খুলুক', v_student.name || ' — ' || p_score::text, 'akhlaq', v_id);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.mdr_rel_save_teacher_log(
  p_actor_id uuid,
  p_pin text,
  p_type text,
  p_student_id uuid,
  p_content text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_student public.mdr_students%rowtype;
  v_id uuid;
begin
  select * into v_actor from public.shared_users
  where id = p_actor_id and is_active = true and pin = p_pin and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_teacher'); end if;
  if p_type not in ('class', 'student') then return jsonb_build_object('ok', false, 'error', 'invalid_type'); end if;
  if btrim(coalesce(p_content, '')) = '' then return jsonb_build_object('ok', false, 'error', 'content_required'); end if;

  if p_type = 'student' then
    select * into v_student from public.mdr_students where id = p_student_id and status = 'active';
    if v_student.id is null then return jsonb_build_object('ok', false, 'error', 'student_not_found'); end if;
    if v_student.current_class_id <> v_actor.class_id then return jsonb_build_object('ok', false, 'error', 'not_teacher_class'); end if;

    insert into public.mdr_logs (type, student_id, content, written_by)
    values ('student', p_student_id, btrim(p_content), v_actor.id)
    returning id into v_id;
  else
    insert into public.mdr_logs (type, class_id, content, written_by)
    values ('class', v_actor.class_id, btrim(p_content), v_actor.id)
    returning id into v_id;
  end if;

  insert into public.shared_notifications (target, title, body, source_type, source_id)
  values ('admin', case when p_type = 'student' then 'নতুন ছাত্র লগ' else 'নতুন বর্ষ লগ' end, btrim(p_content), 'log', v_id);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.mdr_rel_save_book_progress(
  p_actor_id uuid,
  p_pin text,
  p_book_id uuid,
  p_pages_done integer,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_book public.mdr_books%rowtype;
  v_event_id uuid;
begin
  select * into v_actor from public.shared_users
  where id = p_actor_id and is_active = true and pin = p_pin and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_teacher'); end if;
  if p_pages_done is null or p_pages_done < 0 then return jsonb_build_object('ok', false, 'error', 'invalid_pages'); end if;

  select * into v_book from public.mdr_books where id = p_book_id;
  if v_book.id is null then return jsonb_build_object('ok', false, 'error', 'book_not_found'); end if;
  if v_book.class_id <> v_actor.class_id then return jsonb_build_object('ok', false, 'error', 'not_teacher_class'); end if;

  insert into public.mdr_book_progress_events (book_id, class_id, pages_done, notes, updated_by)
  values (p_book_id, v_book.class_id, p_pages_done, nullif(btrim(coalesce(p_note, '')), ''), v_actor.id)
  returning id into v_event_id;

  insert into public.mdr_book_progress (book_id, pages_done, notes, updated_by, updated_at)
  values (p_book_id, p_pages_done, nullif(btrim(coalesce(p_note, '')), ''), v_actor.id, now())
  on conflict (book_id) do update
  set pages_done = excluded.pages_done,
      notes = excluded.notes,
      updated_by = excluded.updated_by,
      updated_at = now();

  insert into public.shared_notifications (target, title, body, source_type, source_id)
  values ('admin', 'কিতাব অগ্রগতি আপডেট', v_book.name || ' — ' || p_pages_done::text || ' পৃষ্ঠা', 'book_progress', v_event_id);

  return jsonb_build_object('ok', true, 'id', v_event_id);
end;
$$;

create or replace function public.mdr_rel_chat_bootstrap(p_actor_id uuid, p_pin text, p_is_admin boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_thread text;
  v_admin boolean := coalesce(p_is_admin, false);
begin
  if v_admin then
    if not private.verify_admin_pin(p_pin) then
      return jsonb_build_object('ok', false, 'error', 'invalid_pin');
    end if;
  else
    select * into v_actor from public.shared_users where id = p_actor_id and is_active = true and pin = p_pin;
    if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_actor'); end if;
    v_thread := private.mdr_actor_thread(v_actor);
  end if;

  return jsonb_build_object(
    'ok', true,
    'messages', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'thread_id', m.thread_id,
        'from_role', m.from_role,
        'from_name', m.from_name,
        'text', m.body,
        'ts', m.created_at,
        'read_admin', m.read_admin,
        'read_staff', m.read_staff
      ) order by m.created_at), '[]'::jsonb)
      from public.shared_messages m
      where v_admin or m.thread_id = v_thread
    ),
    'unread_admin', (
      select count(*) from public.shared_messages m where v_admin and m.from_role <> 'admin' and m.read_admin = false
    ),
    'unread_staff', (
      select count(*) from public.shared_messages m where (not v_admin) and m.thread_id = v_thread and m.from_role = 'admin' and m.read_staff = false
    )
  );
end;
$$;

create or replace function public.mdr_rel_chat_send(
  p_actor_id uuid,
  p_pin text,
  p_thread_id text,
  p_text text,
  p_is_admin boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_thread text;
  v_admin boolean := coalesce(p_is_admin, false);
  v_id uuid;
  v_body text := btrim(coalesce(p_text, ''));
begin
  if v_body = '' then return jsonb_build_object('ok', false, 'error', 'empty_message'); end if;

  if v_admin then
    if not private.verify_admin_pin(p_pin) then
      return jsonb_build_object('ok', false, 'error', 'invalid_pin');
    end if;
    if btrim(coalesce(p_thread_id, '')) = '' then return jsonb_build_object('ok', false, 'error', 'thread_required'); end if;
    insert into public.shared_messages (thread_id, from_user_id, from_role, from_name, body, read_admin, read_staff)
    values (p_thread_id, p_actor_id, 'admin', 'জিম্মাদার', v_body, true, false)
    returning id into v_id;
    insert into public.shared_notifications (target, title, body, source_type, source_id)
    values (p_thread_id, 'জিম্মাদারের নতুন বার্তা', v_body, 'message', v_id);
  else
    select * into v_actor from public.shared_users where id = p_actor_id and is_active = true and pin = p_pin;
    if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_actor'); end if;
    v_thread := private.mdr_actor_thread(v_actor);
    if coalesce(p_thread_id, v_thread) <> v_thread then return jsonb_build_object('ok', false, 'error', 'thread_not_allowed'); end if;
    insert into public.shared_messages (thread_id, from_user_id, from_role, from_name, body, read_admin, read_staff)
    values (v_thread, v_actor.id, v_actor.role, v_actor.name, v_body, false, true)
    returning id into v_id;
    insert into public.shared_notifications (target, title, body, source_type, source_id)
    values ('admin', 'নতুন বার্তা', v_actor.name || ': ' || v_body, 'message', v_id);
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.mdr_rel_chat_mark_read(
  p_actor_id uuid,
  p_pin text,
  p_thread_id text,
  p_is_admin boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_thread text;
  v_admin boolean := coalesce(p_is_admin, false);
begin
  if v_admin then
    if not private.verify_admin_pin(p_pin) then return jsonb_build_object('ok', false, 'error', 'invalid_pin'); end if;
    update public.shared_messages
    set read_admin = true
    where thread_id = p_thread_id and from_role <> 'admin';
  else
    select * into v_actor from public.shared_users where id = p_actor_id and is_active = true and pin = p_pin;
    if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_actor'); end if;
    v_thread := private.mdr_actor_thread(v_actor);
    update public.shared_messages
    set read_staff = true
    where thread_id = v_thread and from_role = 'admin';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.mdr_rel_teacher_class_bootstrap(uuid, text) to anon;
grant execute on function public.mdr_rel_save_akhlaq(uuid, text, uuid, integer, text) to anon;
grant execute on function public.mdr_rel_save_teacher_log(uuid, text, text, uuid, text) to anon;
grant execute on function public.mdr_rel_save_book_progress(uuid, text, uuid, integer, text) to anon;
grant execute on function public.mdr_rel_chat_bootstrap(uuid, text, boolean) to anon;
grant execute on function public.mdr_rel_chat_send(uuid, text, text, text, boolean) to anon;
grant execute on function public.mdr_rel_chat_mark_read(uuid, text, text, boolean) to anon;;
