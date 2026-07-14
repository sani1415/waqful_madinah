create or replace function public.mdr_rel_class_routine_save(p_actor_id uuid, p_pin text, p_slots jsonb, p_change_note text default '')
returns jsonb language plpgsql security definer set search_path = public, private as $$
declare v_actor public.mdr_shared_users%rowtype; v_class public.mdr_classes%rowtype; v_next_version integer; v_routine_id uuid; v_check jsonb;
begin
  select * into v_actor from public.mdr_shared_users where id=p_actor_id and is_active=true and pin=p_pin and role='madrasa_teacher' and class_id is not null;
  if v_actor.id is null then return jsonb_build_object('ok',false,'error','invalid_teacher'); end if;
  select * into v_class from public.mdr_classes where id=v_actor.class_id and is_active=true;
  if v_class.id is null then return jsonb_build_object('ok',false,'error','class_not_found'); end if;
  v_check := private.mdr_class_routine_validate_slots(p_slots);
  if coalesce((v_check->>'ok')::boolean,false)=false then return v_check; end if;
  select coalesce(max(version_no),0)+1 into v_next_version from public.mdr_class_routines where class_id=v_class.id;
  update public.mdr_class_routines set is_current=false where class_id=v_class.id and is_current=true;
  insert into public.mdr_class_routines (class_id,version_no,is_current,change_note,created_by,updated_at)
  values (v_class.id,v_next_version,true,coalesce(nullif(btrim(coalesce(p_change_note,'')),'') ,''),v_actor.id,now()) returning id into v_routine_id;
  perform private.mdr_class_routine_insert_slots(v_routine_id,p_slots);
  return jsonb_build_object('ok',true,'routine_id',v_routine_id,'version_no',v_next_version);
end; $$;;
