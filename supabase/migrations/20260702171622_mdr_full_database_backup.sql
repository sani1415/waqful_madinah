-- Full JSON database backup for the Idarah admin settings page.
-- This exports public application tables as JSON after verifying the main admin PIN.

create or replace function public.mdr_rel_full_database_backup(p_actor_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_table record;
  v_rows jsonb;
  v_count bigint;
  v_tables jsonb := '{}'::jsonb;
  v_counts jsonb := '{}'::jsonb;
begin
  select *
    into v_actor
  from public.mdr_shared_users u
  where u.id = p_actor_id
    and u.is_active = true
    and u.pin = p_pin
    and u.role = 'admin'
  limit 1;

  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object(
      'ok', false,
      'error', 'unauthorized'
    );
  end if;

  for v_table in
    select c.relname as table_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and (
        c.relname ~ '^mdr_'
        or c.relname ~ '^dept_'
        or c.relname ~ '^khedmat_'
        or c.relname ~ '^shared_'
      )
    order by c.relname
  loop
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text), ''[]''::jsonb), count(*) from %I.%I t',
      'public',
      v_table.table_name
    )
    into v_rows, v_count;

    v_tables := jsonb_set(v_tables, array[v_table.table_name], v_rows, true);
    v_counts := jsonb_set(v_counts, array[v_table.table_name], to_jsonb(v_count), true);
  end loop;

  return jsonb_build_object(
    'ok', true,
    'backup_type', 'database_json',
    'app', 'madrasatul-madina-idarah',
    'version', 1,
    'generated_at', now(),
    'generated_by', jsonb_build_object(
      'actor_id', coalesce(v_actor.id, null),
      'role', coalesce(v_actor.role, 'admin')
    ),
    'storage_backup', jsonb_build_object(
      'included', false,
      'note', 'Storage files are exported by the separate storage backup flow.'
    ),
    'table_counts', v_counts,
    'tables', v_tables
  );
end;
$$;

revoke execute on function public.mdr_rel_full_database_backup(uuid, text) from public, authenticated;
grant execute on function public.mdr_rel_full_database_backup(uuid, text) to anon;;
