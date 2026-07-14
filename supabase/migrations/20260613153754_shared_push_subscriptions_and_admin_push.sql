-- Web Push for admin notifications. Additive only; touches no Waqf tables.

-- 1) Subscription store (own prefix, RLS deny-all; access only via SECURITY DEFINER RPC / service role)
create table if not exists public.shared_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  actor_role text not null,
  actor_id uuid,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.shared_push_subscriptions enable row level security;
-- no policies => deny-all for anon/authenticated

create index if not exists shared_push_subscriptions_role_idx
  on public.shared_push_subscriptions (actor_role);

-- 2) Subscribe (upsert by endpoint). Same auth pattern as mdr_rel_chat_send.
create or replace function public.mdr_rel_push_subscribe(
  p_actor_id uuid,
  p_pin text,
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_is_admin boolean default false,
  p_user_agent text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  v_actor public.shared_users%rowtype;
  v_role text;
  v_actor_id uuid;
begin
  if btrim(coalesce(p_endpoint,'')) = ''
     or btrim(coalesce(p_p256dh,'')) = ''
     or btrim(coalesce(p_auth,'')) = '' then
    return jsonb_build_object('ok', false, 'error', 'invalid_subscription');
  end if;

  if coalesce(p_is_admin, false) then
    if not private.verify_admin_pin(p_pin) then
      return jsonb_build_object('ok', false, 'error', 'invalid_pin');
    end if;
    v_role := 'admin';
    v_actor_id := p_actor_id;
  else
    select * into v_actor from public.shared_users
      where id = p_actor_id and is_active = true and pin = p_pin;
    if v_actor.id is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_actor');
    end if;
    v_role := v_actor.role;
    v_actor_id := v_actor.id;
  end if;

  insert into public.shared_push_subscriptions
    (actor_role, actor_id, endpoint, p256dh, auth, user_agent, updated_at)
  values (v_role, v_actor_id, p_endpoint, p_p256dh, p_auth, p_user_agent, now())
  on conflict (endpoint) do update
    set actor_role = excluded.actor_role,
        actor_id   = excluded.actor_id,
        p256dh     = excluded.p256dh,
        auth       = excluded.auth,
        user_agent = excluded.user_agent,
        updated_at = now();

  return jsonb_build_object('ok', true);
end;
$function$;

-- 3) Unsubscribe by endpoint (device knows its own endpoint).
create or replace function public.mdr_rel_push_unsubscribe(p_endpoint text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
begin
  delete from public.shared_push_subscriptions where endpoint = p_endpoint;
  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.mdr_rel_push_subscribe(uuid, text, text, text, text, boolean, text) to anon, authenticated;
grant execute on function public.mdr_rel_push_unsubscribe(text) to anon, authenticated;

-- 4) On a new admin-targeted message notification, fire a web push (async, non-blocking).
create or replace function private.notify_admin_push()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
begin
  if new.target = 'admin' and new.source_type = 'message' then
    begin
      perform net.http_post(
        url := 'https://bbdtoucanihtrymzpynq.supabase.co/functions/v1/send-admin-push',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJiZHRvdWNhbmlodHJ5bXpweW5xIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU3NDA0NjEsImV4cCI6MjA5MTMxNjQ2MX0.TPQtymiXFogCPCrT2ZbYFVZ7ziBrm5NNcB_XgPaPGPw'
        ),
        body := jsonb_build_object(
          'title', new.title,
          'body', new.body,
          'notification_id', new.id
        )
      );
    exception when others then
      -- never block the message/notification insert if push enqueue fails
      null;
    end;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_shared_notifications_admin_push on public.shared_notifications;
create trigger trg_shared_notifications_admin_push
  after insert on public.shared_notifications
  for each row execute function private.notify_admin_push();;
