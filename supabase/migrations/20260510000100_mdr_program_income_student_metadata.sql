-- Return student-linked income metadata from the program bootstrap RPC.

create or replace function public.mdr_rel_programs_bootstrap(p_actor_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
begin
  v_actor := private.mdr_program_actor(p_actor_id, p_pin, true);
  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  return jsonb_build_object(
    'ok', true,
    'read_only', v_actor.role = 'admin',
    'programs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'status', p.status,
        'date', coalesce(p.program_date::text, ''),
        'note', p.note,
        'shareEnabled', coalesce((p.metadata->>'shareEnabled')::boolean, false),
        'incomeTypes', to_jsonb(p.income_types),
        'expenseTypes', to_jsonb(p.expense_types),
        '_at', floor(extract(epoch from p.created_at) * 1000)::bigint,
        '_updatedAt', floor(extract(epoch from p.updated_at) * 1000)::bigint
      ) order by p.created_at, p.id)
      from public.mdr_programs p
    ), '[]'::jsonb),
    'income', coalesce((
      select jsonb_object_agg(program_id, rows)
      from (
        select i.program_id, jsonb_agg(jsonb_build_object(
          'id', i.id,
          'date', coalesce(i.entry_date::text, ''),
          'type', i.type,
          'personType', i.person_type,
          'name', i.name,
          'studentId', coalesce(i.metadata->>'studentId', ''),
          'studentPermanentId', coalesce(i.metadata->>'studentPermanentId', ''),
          'studentClassId', coalesce(i.metadata->>'studentClassId', ''),
          'share', i.share,
          'amount', i.amount,
          'ref', i.ref,
          '_at', floor(extract(epoch from i.created_at) * 1000)::bigint,
          '_updatedAt', floor(extract(epoch from i.updated_at) * 1000)::bigint
        ) order by i.entry_date nulls last, i.created_at, i.id) as rows
        from public.mdr_program_incomes i
        group by i.program_id
      ) s
    ), '{}'::jsonb),
    'expense', coalesce((
      select jsonb_object_agg(program_id, rows)
      from (
        select e.program_id, jsonb_agg(jsonb_build_object(
          'id', e.id,
          'date', coalesce(e.entry_date::text, ''),
          'type', e.type,
          'amount', e.amount,
          'note', e.note,
          '_at', floor(extract(epoch from e.created_at) * 1000)::bigint,
          '_updatedAt', floor(extract(epoch from e.updated_at) * 1000)::bigint
        ) order by e.entry_date nulls last, e.created_at, e.id) as rows
        from public.mdr_program_expenses e
        group by e.program_id
      ) s
    ), '{}'::jsonb),
    'attachments', coalesce((
      select jsonb_object_agg(expense_id, rows)
      from (
        select a.expense_id, jsonb_agg(jsonb_build_object(
          'id', a.id,
          'programId', a.program_id,
          'expenseId', a.expense_id,
          'bucketId', a.bucket_id,
          'storagePath', a.storage_path,
          'fileName', a.file_name,
          'mimeType', a.mime_type,
          'fileSize', a.file_size,
          '_at', floor(extract(epoch from a.created_at) * 1000)::bigint
        ) order by a.created_at, a.id) as rows
        from public.mdr_program_expense_attachments a
        group by a.expense_id
      ) s
    ), '{}'::jsonb)
  );
end;
$$;
revoke execute on function public.mdr_rel_programs_bootstrap(uuid, text) from public, authenticated;
grant execute on function public.mdr_rel_programs_bootstrap(uuid, text) to anon;
