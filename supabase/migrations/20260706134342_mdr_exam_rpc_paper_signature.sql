-- Fix exam RPC signatures for PostgREST (404 when extra params sent).
-- Add optional question-paper fields; keep mdr_shared_users auth.

alter table public.mdr_exams
  add column if not exists paper_name text not null default '',
  add column if not exists paper_data text not null default '';

create or replace function public.mdr_rel_exam_bootstrap(
  p_actor_id uuid,
  p_pin      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_class public.mdr_classes%rowtype;
  v_exams jsonb;
begin
  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin
    and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  select * into v_class from public.mdr_classes where id = v_actor.class_id;

  select jsonb_agg(
    jsonb_build_object(
      'id',         e.id,
      'name',       e.name,
      'type',       e.type,
      'class_code', v_class.code,
      'created_at', e.created_at,
      'paper_name', coalesce(e.paper_name, ''),
      'paper_data', coalesce(e.paper_data, ''),
      'subjects', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id',         s.id,
            'name',       s.name,
            'max_marks',  s.max_marks,
            'sort_order', s.sort_order
          ) order by s.sort_order, s.id
        )
        from public.mdr_exam_subjects s where s.exam_id = e.id
      ), '[]'::jsonb),
      'results', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'student_id', r.student_id,
            'subject_id', r.subject_id,
            'marks',      r.marks
          )
        )
        from public.mdr_exam_results r where r.exam_id = e.id
      ), '[]'::jsonb)
    ) order by e.created_at desc
  )
  into v_exams
  from public.mdr_exams e
  where e.class_id = v_actor.class_id;

  return jsonb_build_object(
    'ok',         true,
    'class_code', v_class.code,
    'exams',      coalesce(v_exams, '[]'::jsonb)
  );
end;
$$;

create or replace function public.mdr_rel_save_exam(
  p_actor_id uuid,
  p_pin      text,
  p_name     text,
  p_type     text,
  p_subjects jsonb,
  p_paper_name text default null,
  p_paper_data text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor   public.mdr_shared_users%rowtype;
  v_exam_id uuid;
  v_subj    jsonb;
  v_i       integer := 0;
begin
  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin
    and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;
  if p_type not in ('weekly','monthly','half_yearly','yearly','test') then
    return jsonb_build_object('ok', false, 'error', 'invalid_type');
  end if;
  if btrim(coalesce(p_name,'')) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;
  if jsonb_array_length(coalesce(p_subjects,'[]'::jsonb)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'subjects_required');
  end if;

  insert into public.mdr_exams (name, type, class_id, created_by, paper_name, paper_data)
  values (
    btrim(p_name),
    p_type,
    v_actor.class_id,
    v_actor.id,
    coalesce(p_paper_name, ''),
    coalesce(p_paper_data, '')
  )
  returning id into v_exam_id;

  for v_subj in select * from jsonb_array_elements(p_subjects) loop
    insert into public.mdr_exam_subjects (exam_id, name, max_marks, sort_order)
    values (
      v_exam_id,
      btrim(v_subj->>'name'),
      coalesce((v_subj->>'max_marks')::integer, 100),
      v_i
    );
    v_i := v_i + 1;
  end loop;

  return jsonb_build_object('ok', true, 'id', v_exam_id);
end;
$$;

create or replace function public.mdr_rel_update_exam(
  p_actor_id uuid,
  p_pin      text,
  p_exam_id  uuid,
  p_name     text,
  p_type     text,
  p_subjects jsonb default null,
  p_paper_name text default null,
  p_paper_data text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_exam  public.mdr_exams%rowtype;
  v_subj  jsonb;
  v_i     integer := 0;
begin
  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin
    and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  select * into v_exam from public.mdr_exams where id = p_exam_id;
  if v_exam.id is null then
    return jsonb_build_object('ok', false, 'error', 'exam_not_found');
  end if;
  if v_exam.class_id <> v_actor.class_id then
    return jsonb_build_object('ok', false, 'error', 'not_your_class');
  end if;
  if btrim(coalesce(p_name,'')) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;
  if p_type not in ('weekly','monthly','half_yearly','yearly','test') then
    return jsonb_build_object('ok', false, 'error', 'invalid_type');
  end if;

  update public.mdr_exams
  set name = btrim(p_name),
      type = p_type,
      paper_name = case when p_paper_name is not null then p_paper_name else paper_name end,
      paper_data = case when p_paper_data is not null then p_paper_data else paper_data end
  where id = p_exam_id;

  if p_subjects is not null then
    if exists (select 1 from public.mdr_exam_results where exam_id = p_exam_id) then
      return jsonb_build_object('ok', false, 'error', 'has_results_cannot_change_subjects');
    end if;
    if jsonb_array_length(p_subjects) = 0 then
      return jsonb_build_object('ok', false, 'error', 'subjects_required');
    end if;
    delete from public.mdr_exam_subjects where exam_id = p_exam_id;
    for v_subj in select * from jsonb_array_elements(p_subjects) loop
      insert into public.mdr_exam_subjects (exam_id, name, max_marks, sort_order)
      values (p_exam_id, btrim(v_subj->>'name'), coalesce((v_subj->>'max_marks')::integer, 100), v_i);
      v_i := v_i + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.mdr_rel_delete_exam(
  p_actor_id uuid,
  p_pin      text,
  p_exam_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_exam  public.mdr_exams%rowtype;
begin
  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin
    and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  select * into v_exam from public.mdr_exams where id = p_exam_id;
  if v_exam.id is null then
    return jsonb_build_object('ok', false, 'error', 'exam_not_found');
  end if;
  if v_exam.class_id <> v_actor.class_id then
    return jsonb_build_object('ok', false, 'error', 'not_your_class');
  end if;

  delete from public.mdr_exams where id = p_exam_id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.mdr_rel_save_exam_results(
  p_actor_id uuid,
  p_pin      text,
  p_exam_id  uuid,
  p_results  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_exam  public.mdr_exams%rowtype;
  v_row   jsonb;
  v_count integer := 0;
begin
  select * into v_actor from public.mdr_shared_users
  where id = p_actor_id and is_active = true and pin = p_pin
    and role = 'madrasa_teacher' and class_id is not null;
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_teacher');
  end if;

  select * into v_exam from public.mdr_exams where id = p_exam_id;
  if v_exam.id is null then
    return jsonb_build_object('ok', false, 'error', 'exam_not_found');
  end if;
  if v_exam.class_id <> v_actor.class_id then
    return jsonb_build_object('ok', false, 'error', 'not_your_class');
  end if;

  for v_row in select * from jsonb_array_elements(coalesce(p_results,'[]'::jsonb)) loop
    insert into public.mdr_exam_results (exam_id, student_id, subject_id, marks)
    values (
      p_exam_id,
      (v_row->>'student_id')::uuid,
      (v_row->>'subject_id')::uuid,
      (v_row->>'marks')::numeric
    )
    on conflict (exam_id, student_id, subject_id)
    do update set marks = excluded.marks, created_at = now();
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'count', v_count);
end;
$$;

revoke execute on function public.mdr_rel_exam_bootstrap(uuid, text) from public, authenticated;
revoke execute on function public.mdr_rel_save_exam(uuid, text, text, text, jsonb, text, text) from public, authenticated;
revoke execute on function public.mdr_rel_update_exam(uuid, text, uuid, text, text, jsonb, text, text) from public, authenticated;
revoke execute on function public.mdr_rel_delete_exam(uuid, text, uuid) from public, authenticated;
revoke execute on function public.mdr_rel_save_exam_results(uuid, text, uuid, jsonb) from public, authenticated;

grant execute on function public.mdr_rel_exam_bootstrap(uuid, text) to anon;
grant execute on function public.mdr_rel_save_exam(uuid, text, text, text, jsonb, text, text) to anon;
grant execute on function public.mdr_rel_update_exam(uuid, text, uuid, text, text, jsonb, text, text) to anon;
grant execute on function public.mdr_rel_delete_exam(uuid, text, uuid) to anon;
grant execute on function public.mdr_rel_save_exam_results(uuid, text, uuid, jsonb) to anon;

drop function if exists public.mdr_rel_save_exam(uuid, text, text, text, jsonb);
drop function if exists public.mdr_rel_update_exam(uuid, text, uuid, text, text, jsonb);;
