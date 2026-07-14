create or replace function public.mdr_rel_hifz_eligible_students(
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
begin
  v_actor := private.verify_hifz_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  return jsonb_build_object(
    'ok', true,
    'students', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'roll', s.current_roll,
        'permanent_id', s.student_id,
        'class_name', c.name
      ) order by c.sort_order, s.current_roll, s.name), '[]'::jsonb)
      from public.mdr_students s
      left join public.mdr_classes c on c.id = s.current_class_id
      where s.status = 'active'
    )
  );
end;
$$;

revoke execute on function public.mdr_rel_hifz_eligible_students(uuid, text) from public, authenticated;
grant execute on function public.mdr_rel_hifz_eligible_students(uuid, text) to anon;;
