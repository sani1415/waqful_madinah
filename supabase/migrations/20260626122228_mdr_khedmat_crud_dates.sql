-- Complete Khedmat-e-Khalq CRUD and back-dated entry support.
-- Scope is limited to the mdr_khedmat_* namespace.

alter table if exists public.mdr_khedmat_activities
  add column if not exists updated_by uuid references public.mdr_shared_users(id) on delete set null;

alter table if exists public.mdr_khedmat_daily_logs
  add column if not exists updated_by uuid references public.mdr_shared_users(id) on delete set null,
  add column if not exists updated_at timestamptz not null default now();

alter table if exists public.mdr_khedmat_finance
  add column if not exists updated_by uuid references public.mdr_shared_users(id) on delete set null,
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.mdr_khedmat_rel_upsert_activity(
  p_actor_id uuid,
  p_pin text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
  v_type_id text;
  v_beneficiary_id text;
  v_amount numeric;
  v_row public.mdr_khedmat_activities%rowtype;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  v_beneficiary_id := nullif(btrim(coalesce(p_payload->>'beneficiary_id', '')), '');
  if v_beneficiary_id is null or not exists (
    select 1 from public.mdr_khedmat_beneficiaries where id = v_beneficiary_id
  ) then
    return jsonb_build_object('ok', false, 'error', 'beneficiary_not_found');
  end if;

  if nullif(btrim(coalesce(p_payload->>'title', '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'title_required');
  end if;

  v_amount := coalesce(nullif(p_payload->>'amount', '')::numeric, 0);
  if v_amount < 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;

  v_id := coalesce(nullif(btrim(p_payload->>'id'), ''), private.khedmat_new_id('act'));
  v_type_id := nullif(btrim(coalesce(p_payload->>'type_id', '')), '');
  if v_type_id is not null and not exists (select 1 from public.mdr_khedmat_activity_types where id = v_type_id) then
    v_type_id := null;
  end if;

  update public.mdr_khedmat_activities
  set beneficiary_id = v_beneficiary_id,
      type_id = v_type_id,
      title = btrim(p_payload->>'title'),
      description = coalesce(p_payload->>'description', ''),
      amount = v_amount,
      activity_date = coalesce(nullif(p_payload->>'date', '')::date, current_date),
      images = case
        when p_payload ? 'images' then coalesce(p_payload->'images', '[]'::jsonb)
        else images
      end,
      updated_by = v_actor.id,
      updated_at = now()
  where id = v_id
  returning * into v_row;

  if v_row.id is null then
    insert into public.mdr_khedmat_activities (
      id, beneficiary_id, type_id, title, description, amount, activity_date, images, created_by, updated_by
    )
    values (
      v_id,
      v_beneficiary_id,
      v_type_id,
      btrim(p_payload->>'title'),
      coalesce(p_payload->>'description', ''),
      v_amount,
      coalesce(nullif(p_payload->>'date', '')::date, current_date),
      coalesce(p_payload->'images', '[]'::jsonb),
      v_actor.id,
      v_actor.id
    )
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'ok', true,
    'activity', jsonb_build_object(
      'id', v_row.id,
      'beneficiary_id', v_row.beneficiary_id,
      'type_id', v_row.type_id,
      'title', v_row.title,
      'description', v_row.description,
      'amount', v_row.amount,
      'date', v_row.activity_date,
      'images', v_row.images
    )
  );
end;
$$;

create or replace function public.mdr_khedmat_rel_insert_activity(
  p_actor_id uuid,
  p_pin text,
  p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select public.mdr_khedmat_rel_upsert_activity(p_actor_id, p_pin, p_payload);
$$;

create or replace function public.mdr_khedmat_rel_delete_activity(
  p_actor_id uuid,
  p_pin text,
  p_activity_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  delete from public.mdr_khedmat_activities
  where id = p_activity_id
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'activity', jsonb_build_object('id', v_id));
end;
$$;

create or replace function public.mdr_khedmat_rel_upsert_daily_log(
  p_actor_id uuid,
  p_pin text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
  v_row public.mdr_khedmat_daily_logs%rowtype;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;
  if nullif(btrim(coalesce(p_payload->>'content', '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'content_required');
  end if;

  v_id := coalesce(nullif(btrim(p_payload->>'id'), ''), private.khedmat_new_id('lg'));

  update public.mdr_khedmat_daily_logs
  set content = btrim(p_payload->>'content'),
      by_name = nullif(btrim(coalesce(p_payload->>'by', '')), ''),
      log_date = coalesce(nullif(p_payload->>'date', '')::date, current_date),
      updated_by = v_actor.id,
      updated_at = now()
  where id = v_id
  returning * into v_row;

  if v_row.id is null then
    insert into public.mdr_khedmat_daily_logs (id, content, by_name, log_date, created_by, updated_by)
    values (
      v_id,
      btrim(p_payload->>'content'),
      nullif(btrim(coalesce(p_payload->>'by', '')), ''),
      coalesce(nullif(p_payload->>'date', '')::date, current_date),
      v_actor.id,
      v_actor.id
    )
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'ok', true,
    'log', jsonb_build_object('id', v_row.id, 'content', v_row.content, 'by', v_row.by_name, 'date', v_row.log_date)
  );
end;
$$;

create or replace function public.mdr_khedmat_rel_insert_daily_log(
  p_actor_id uuid,
  p_pin text,
  p_content text,
  p_by text default null
)
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select public.mdr_khedmat_rel_upsert_daily_log(
    p_actor_id,
    p_pin,
    jsonb_build_object('content', coalesce(p_content, ''), 'by', p_by, 'date', current_date)
  );
$$;

create or replace function public.mdr_khedmat_rel_delete_daily_log(
  p_actor_id uuid,
  p_pin text,
  p_log_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  delete from public.mdr_khedmat_daily_logs
  where id = p_log_id
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'log', jsonb_build_object('id', v_id));
end;
$$;

create or replace function public.mdr_khedmat_rel_upsert_finance(
  p_actor_id uuid,
  p_pin text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
  v_activity_id text;
  v_amount numeric;
  v_row public.mdr_khedmat_finance%rowtype;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;
  if coalesce(p_payload->>'type', '') not in ('income', 'expense') then
    return jsonb_build_object('ok', false, 'error', 'invalid_type');
  end if;

  v_amount := coalesce(nullif(p_payload->>'amount', '')::numeric, 0);
  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;
  if nullif(btrim(coalesce(p_payload->>'description', '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'description_required');
  end if;

  v_activity_id := nullif(btrim(coalesce(p_payload->>'activity_id', '')), '');
  if v_activity_id is not null and not exists (select 1 from public.mdr_khedmat_activities where id = v_activity_id) then
    return jsonb_build_object('ok', false, 'error', 'activity_not_found');
  end if;

  v_id := coalesce(nullif(btrim(p_payload->>'id'), ''), private.khedmat_new_id('fn'));

  update public.mdr_khedmat_finance
  set type = p_payload->>'type',
      amount = v_amount,
      description = btrim(p_payload->>'description'),
      source = nullif(btrim(coalesce(p_payload->>'source', '')), ''),
      activity_id = v_activity_id,
      txn_date = coalesce(nullif(p_payload->>'date', '')::date, current_date),
      updated_by = v_actor.id,
      updated_at = now()
  where id = v_id
  returning * into v_row;

  if v_row.id is null then
    insert into public.mdr_khedmat_finance (
      id, type, amount, description, source, activity_id, txn_date, created_by, updated_by
    )
    values (
      v_id,
      p_payload->>'type',
      v_amount,
      btrim(p_payload->>'description'),
      nullif(btrim(coalesce(p_payload->>'source', '')), ''),
      v_activity_id,
      coalesce(nullif(p_payload->>'date', '')::date, current_date),
      v_actor.id,
      v_actor.id
    )
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'ok', true,
    'finance', jsonb_build_object(
      'id', v_row.id,
      'type', v_row.type,
      'amount', v_row.amount,
      'description', v_row.description,
      'source', v_row.source,
      'activity_id', v_row.activity_id,
      'date', v_row.txn_date
    )
  );
end;
$$;

create or replace function public.mdr_khedmat_rel_insert_finance(
  p_actor_id uuid,
  p_pin text,
  p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select public.mdr_khedmat_rel_upsert_finance(p_actor_id, p_pin, p_payload);
$$;

create or replace function public.mdr_khedmat_rel_delete_finance(
  p_actor_id uuid,
  p_pin text,
  p_finance_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  delete from public.mdr_khedmat_finance
  where id = p_finance_id
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'finance', jsonb_build_object('id', v_id));
end;
$$;

create or replace function public.mdr_khedmat_rel_delete_beneficiary(
  p_actor_id uuid,
  p_pin text,
  p_beneficiary_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_id text;
begin
  v_actor := private.verify_khedmat_actor(p_actor_id, p_pin);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  delete from public.mdr_khedmat_beneficiaries
  where id = p_beneficiary_id
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'beneficiary', jsonb_build_object('id', v_id));
end;
$$;

revoke execute on function public.mdr_khedmat_rel_upsert_activity(uuid, text, jsonb) from public, authenticated;
revoke execute on function public.mdr_khedmat_rel_delete_activity(uuid, text, text) from public, authenticated;
revoke execute on function public.mdr_khedmat_rel_upsert_daily_log(uuid, text, jsonb) from public, authenticated;
revoke execute on function public.mdr_khedmat_rel_delete_daily_log(uuid, text, text) from public, authenticated;
revoke execute on function public.mdr_khedmat_rel_upsert_finance(uuid, text, jsonb) from public, authenticated;
revoke execute on function public.mdr_khedmat_rel_delete_finance(uuid, text, text) from public, authenticated;
revoke execute on function public.mdr_khedmat_rel_delete_beneficiary(uuid, text, text) from public, authenticated;

grant execute on function public.mdr_khedmat_rel_upsert_activity(uuid, text, jsonb) to anon;
grant execute on function public.mdr_khedmat_rel_delete_activity(uuid, text, text) to anon;
grant execute on function public.mdr_khedmat_rel_upsert_daily_log(uuid, text, jsonb) to anon;
grant execute on function public.mdr_khedmat_rel_delete_daily_log(uuid, text, text) to anon;
grant execute on function public.mdr_khedmat_rel_upsert_finance(uuid, text, jsonb) to anon;
grant execute on function public.mdr_khedmat_rel_delete_finance(uuid, text, text) to anon;
grant execute on function public.mdr_khedmat_rel_delete_beneficiary(uuid, text, text) to anon;;
