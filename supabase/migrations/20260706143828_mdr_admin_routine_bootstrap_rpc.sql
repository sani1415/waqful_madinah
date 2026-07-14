create or replace function public.mdr_rel_admin_routine_bootstrap(
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
  v_is_super boolean;
begin
  v_actor := private.mdr_admin_dashboard_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  v_is_super := v_actor.role = 'admin'
    or coalesce(v_actor.admin_perms->>'super_admin', 'false') = 'true';

  if not v_is_super
     and coalesce(v_actor.admin_perms->'permissions'->>'dars', 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', 'permission_denied');
  end if;

  if v_is_super then
    v_depts := array['kitab', 'maktab']::text[];
  else
    select array(
      select value
      from jsonb_array_elements_text(coalesce(v_actor.admin_perms->'scope'->'madrasa_depts', '[]'::jsonb)) as t(value)
      where value in ('kitab', 'maktab')
    ) into v_depts;
  end if;

  if coalesce(array_length(v_depts, 1), 0) = 0 then
    return jsonb_build_object('ok', true, 'classes', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ok', true,
    'classes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'code', c.code,
        'name', c.name,
        'sort_order', c.sort_order,
        'division_code', d.code,
        'current_version_no', r.version_no,
        'current_updated_at', r.created_at,
        'has_routine', r.id is not null
      ) order by d.code, c.sort_order, c.name), '[]'::jsonb)
      from public.mdr_classes c
      join public.mdr_divisions d on d.id = c.division_id
      left join public.mdr_class_routines r
        on r.class_id = c.id and r.is_current = true
      where c.is_active = true
        and c.code <> 'kitab_hifz'
        and d.code = any(v_depts)
    )
  );
end;
$$;

revoke execute on function private.mdr_routine_time_sort_key(smallint, smallint, text) from public, anon, authenticated;
revoke execute on function private.mdr_class_routine_slots_json(uuid) from public, anon, authenticated;
revoke execute on function private.mdr_class_routine_can_read(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.mdr_rel_admin_routine_bootstrap(uuid, text) from public, authenticated;
grant execute on function public.mdr_rel_admin_routine_bootstrap(uuid, text) to anon;;
