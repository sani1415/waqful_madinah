create or replace function public.madrasa_student_lock_hints()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  core_val jsonb;
  stud jsonb;
  sid text;
  thread jsonb;
  msg jsonb;
  n int;
  hints jsonb := '[]'::jsonb;
  one jsonb;
begin
  select value into core_val from public.app_kv where key = 'core';
  if core_val is null then return '[]'::jsonb; end if;
  for stud in select * from jsonb_array_elements(coalesce(core_val->'students', '[]'::jsonb))
  loop
    sid := stud->>'id';
    if sid is null then continue; end if;
    thread := core_val->'chats'->sid;
    n := 0;
    if thread is not null and jsonb_typeof(thread) = 'array' then
      for msg in select * from jsonb_array_elements(thread)
      loop
        if (msg->>'role') = 'out' and coalesce((msg->>'read')::boolean, false) = false then
          n := n + 1;
        end if;
      end loop;
    end if;
    if n > 0 then
      one := jsonb_build_object(
        'id', sid,
        'name', coalesce(stud->>'name', ''),
        'waqfId', coalesce(stud->>'waqfId', ''),
        'color', coalesce(stud->>'color', '#1565C0'),
        'unread', n
      );
      hints := hints || jsonb_build_array(one);
    end if;
  end loop;
  return hints;
end;
$$;
grant execute on function public.madrasa_student_lock_hints() to anon, authenticated;;
