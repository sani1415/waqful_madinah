create or replace function public.mdr_rel_class_routine_update(p_actor_id uuid, p_pin text, p_slots jsonb, p_change_note text default null)
returns jsonb language plpgsql security definer set search_path = public, private as $$
declare v_actor public.mdr_shared_users%rowtype; v_routine public.mdr_class_routines%rowtype; v_check jsonb;
begin
  select * into v_actor from public.mdr_shared_users where id=p_actor_id and is_active=true and pin=p_pin and role='madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok',false,'error','invalid_teacher'); end if;
  select * into v_routine from public.mdr_class_routines where class_id=v_actor.class_id and is_current=true limit 1;
  if v_routine.id is null then return jsonb_build_object('ok',false,'error','no_current_routine'); end if;
  v_check := private.mdr_class_routine_validate_slots(p_slots);
  if coalesce((v_check->>'ok')::boolean,false)=false then return v_check; end if;
  delete from public.mdr_class_routine_slots where routine_id=v_routine.id;
  perform private.mdr_class_routine_insert_slots(v_routine.id,p_slots);
  update public.mdr_class_routines set updated_at=now(), change_note=case when nullif(btrim(coalesce(p_change_note,'')),'') is not null then btrim(p_change_note) else change_note end where id=v_routine.id;
  return jsonb_build_object('ok',true,'routine_id',v_routine.id,'version_no',v_routine.version_no);
end; $$;

create or replace function public.mdr_rel_class_routine_delete(p_actor_id uuid, p_pin text, p_routine_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private as $$
declare v_actor public.mdr_shared_users%rowtype; v_routine public.mdr_class_routines%rowtype; v_count integer; v_next public.mdr_class_routines%rowtype;
begin
  select * into v_actor from public.mdr_shared_users where id=p_actor_id and is_active=true and pin=p_pin and role='madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok',false,'error','invalid_teacher'); end if;
  select * into v_routine from public.mdr_class_routines where id=p_routine_id and class_id=v_actor.class_id;
  if v_routine.id is null then return jsonb_build_object('ok',false,'error','routine_not_found'); end if;
  select count(*)::integer into v_count from public.mdr_class_routines where class_id=v_actor.class_id;
  if v_count <= 1 then delete from public.mdr_class_routines where id=v_routine.id; return jsonb_build_object('ok',true,'deleted_all',true); end if;
  if v_routine.is_current then
    select * into v_next from public.mdr_class_routines where class_id=v_actor.class_id and id<>v_routine.id order by version_no desc limit 1;
    update public.mdr_class_routines set is_current=false where class_id=v_actor.class_id and is_current=true;
    update public.mdr_class_routines set is_current=true, updated_at=now() where id=v_next.id;
  end if;
  delete from public.mdr_class_routines where id=v_routine.id;
  return jsonb_build_object('ok',true,'deleted_all',false,'new_current_id',case when v_routine.is_current then v_next.id else null end);
end; $$;

revoke execute on function public.mdr_rel_class_routine_update(uuid, text, jsonb, text) from public, authenticated;
grant execute on function public.mdr_rel_class_routine_update(uuid, text, jsonb, text) to anon;
revoke execute on function public.mdr_rel_class_routine_delete(uuid, text, uuid) from public, authenticated;
grant execute on function public.mdr_rel_class_routine_delete(uuid, text, uuid) to anon;;
