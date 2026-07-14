
-- trigger function-এ thread_id যোগ করি যাতে notification-click সরাসরি thread খোলে।
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
      'thread_id', NEW.thread_id
    ),
    timeout_milliseconds := 5000
  );

  return NEW;
end;
$$;
;
