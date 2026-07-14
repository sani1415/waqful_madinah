-- রিভিউ-কিউ পেজের জন্য হালকা, সরাসরি RPC — শুধু pending log/tag আইটেম রিটার্ন করে
-- (পুরো admin madrasa bootstrap-এর মতো ভারী attendance/students/books পেলোড লাগবে না)।

create or replace function public.mdr_rel_admin_pending_review_items(
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

  return jsonb_build_object(
    'ok', true,
    'logs', (
      case when coalesce(array_length(v_depts, 1), 0) = 0 then '[]'::jsonb else (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', l.id,
          'type', l.type,
          'content', l.content,
          'date', l.created_at::date,
          'by', coalesce(u.name, ''),
          'context', case when l.type = 'class' then c.name else s.name end
        ) order by l.created_at desc), '[]'::jsonb)
        from public.mdr_logs l
        left join public.mdr_students s on s.id = l.student_id
        join public.mdr_classes c on c.id = coalesce(l.class_id, s.current_class_id)
        join public.mdr_divisions d on d.id = c.division_id
        left join public.mdr_shared_users u on u.id = l.written_by
        where l.reviewed_at is null
          and (l.type = 'class' or l.review_requested = true)
          and d.code = any(v_depts)
      ) end
    ),
    'tags', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'thread_id', m.thread_id,
        'from_name', m.from_name,
        'text', m.body,
        'ts', m.created_at,
        'student_name', m.request->>'studentName'
      ) order by m.created_at desc), '[]'::jsonb)
      from public.mdr_shared_messages m
      where m.request is not null
        and m.request->>'kind' = 'student_tag'
        and coalesce(m.request->>'status', 'pending') = 'pending'
    )
  );
end;
$$;

grant execute on function public.mdr_rel_admin_pending_review_items(uuid, text) to anon;;
