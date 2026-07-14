-- 024_mdr_chat_request_metadata.sql
-- Persist structured chat approval requests for accounting edits/deletes.
-- Existing Waqf app tables are intentionally untouched.

alter table public.shared_messages
add column if not exists request jsonb;

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
        'read_staff', m.read_staff,
        'request', m.request
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
  p_is_admin boolean default false,
  p_request jsonb default null
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
    insert into public.shared_messages (thread_id, from_user_id, from_role, from_name, body, read_admin, read_staff, request)
    values (p_thread_id, p_actor_id, 'admin', 'জিম্মাদার', v_body, true, false, p_request)
    returning id into v_id;
    insert into public.shared_notifications (target, title, body, source_type, source_id)
    values (p_thread_id, 'জিম্মাদারের নতুন বার্তা', v_body, 'message', v_id);
  else
    select * into v_actor from public.shared_users where id = p_actor_id and is_active = true and pin = p_pin;
    if v_actor.id is null then return jsonb_build_object('ok', false, 'error', 'invalid_actor'); end if;
    v_thread := private.mdr_actor_thread(v_actor);
    if coalesce(p_thread_id, v_thread) <> v_thread then return jsonb_build_object('ok', false, 'error', 'thread_not_allowed'); end if;
    insert into public.shared_messages (thread_id, from_user_id, from_role, from_name, body, read_admin, read_staff, request)
    values (v_thread, v_actor.id, v_actor.role, v_actor.name, v_body, false, true, p_request)
    returning id into v_id;
    insert into public.shared_notifications (target, title, body, source_type, source_id)
    values ('admin', 'নতুন বার্তা', v_actor.name || ': ' || v_body, 'message', v_id);
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.mdr_rel_chat_update_request(
  p_actor_id uuid,
  p_pin text,
  p_message_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_msg public.shared_messages%rowtype;
begin
  if not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;
  if p_status not in ('approved', 'rejected') then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;

  select * into v_msg from public.shared_messages where id = p_message_id;
  if v_msg.id is null then return jsonb_build_object('ok', false, 'error', 'message_not_found'); end if;
  if v_msg.request is null then return jsonb_build_object('ok', false, 'error', 'request_not_found'); end if;
  if coalesce(v_msg.request->>'status', 'pending') <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'request_already_reviewed');
  end if;

  update public.shared_messages
  set request = request || jsonb_build_object(
        'status', p_status,
        'reviewedAt', now(),
        'reviewedBy', 'জিম্মাদার'
      ),
      read_staff = false
  where id = p_message_id;

  return jsonb_build_object('ok', true, 'id', p_message_id);
end;
$$;

grant execute on function public.mdr_rel_chat_bootstrap(uuid, text, boolean) to anon;
grant execute on function public.mdr_rel_chat_send(uuid, text, text, text, boolean, jsonb) to anon;
grant execute on function public.mdr_rel_chat_update_request(uuid, text, uuid, text) to anon;;
