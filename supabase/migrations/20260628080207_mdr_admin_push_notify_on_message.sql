
-- নতুন staff→admin বার্তা এলে admin-এর PWA-তে web push নোটিফিকেশন পাঠায়।
-- send-admin-push edge function কে pg_net দিয়ে কল করে; secret Vault থেকে পড়ে
-- (repo-তে raw secret রাখা হয় না)। admin নিজের বার্তায় trigger fire করে না।
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
      'body', NEW.body
    ),
    timeout_milliseconds := 5000
  );

  return NEW;
end;
$$;

revoke all on function private.mdr_notify_admin_new_message() from public, anon, authenticated;

drop trigger if exists mdr_shared_messages_notify_admin on public.mdr_shared_messages;
create trigger mdr_shared_messages_notify_admin
  after insert on public.mdr_shared_messages
  for each row
  when (NEW.from_role is distinct from 'admin')
  execute function private.mdr_notify_admin_new_message();
;
