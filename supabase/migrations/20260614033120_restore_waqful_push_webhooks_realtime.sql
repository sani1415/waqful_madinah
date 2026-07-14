-- Restore Waqful Madinah background push webhooks and in-app realtime publication.

DROP TRIGGER IF EXISTS notify_new_message ON public.messages;
CREATE TRIGGER notify_new_message
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION supabase_functions.http_request(
    'https://bbdtoucanihtrymzpynq.supabase.co/functions/v1/notify-kv-push',
    'POST',
    '{"Content-Type":"application/json","x-notify-secret":"waqful_notify_20260614_Z7Q4mN9sR2vK8pL3"}',
    '{}',
    '5000'
  );

DROP TRIGGER IF EXISTS notify_app_kv_push ON public.app_kv;
CREATE TRIGGER notify_app_kv_push
  AFTER INSERT OR UPDATE ON public.app_kv
  FOR EACH ROW
  EXECUTE FUNCTION supabase_functions.http_request(
    'https://bbdtoucanihtrymzpynq.supabase.co/functions/v1/notify-kv-push',
    'POST',
    '{"Content-Type":"application/json","x-notify-secret":"waqful_notify_20260614_Z7Q4mN9sR2vK8pL3"}',
    '{}',
    '5000'
  );

ALTER PUBLICATION supabase_realtime ADD TABLE
  public.messages,
  public.students,
  public.tasks,
  public.task_assignments,
  public.task_completions,
  public.quizzes,
  public.daily_schedule_rows,
  public.daily_schedule_proposals;;
