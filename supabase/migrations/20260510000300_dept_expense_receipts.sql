-- 20260510000300_dept_expense_receipts.sql
-- Department expense receipt storage and bootstrap metadata preservation.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'dept-expense-receipts',
  'dept-expense-receipts',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']::text[]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "anon_insert_dept_expense_receipts" on storage.objects;
create policy "anon_insert_dept_expense_receipts" on storage.objects
for insert to anon
with check (bucket_id = 'dept-expense-receipts');
drop policy if exists "anon_select_dept_expense_receipts" on storage.objects;
create policy "anon_select_dept_expense_receipts" on storage.objects
for select to anon
using (bucket_id = 'dept-expense-receipts');
drop policy if exists "anon_update_dept_expense_receipts" on storage.objects;
create policy "anon_update_dept_expense_receipts" on storage.objects
for update to anon
using (bucket_id = 'dept-expense-receipts')
with check (bucket_id = 'dept-expense-receipts');
create or replace function public.dept_rel_bootstrap(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_dept_code text;
  v_dept_id uuid;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;

  v_dept_code := coalesce(nullif(btrim(p_dept_code), ''), v_actor.dept_code);

  select id into v_dept_id
  from public.dept_departments
  where code = v_dept_code and is_active = true;

  if v_dept_id is null then
    return jsonb_build_object('ok', false, 'error', 'dept_not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'dept_id', v_dept_code,
        'name', p.name,
        'unit', p.unit,
        'price', p.price,
        'is_active', p.is_active
      ) order by p.sort_order, p.name)
      from public.dept_products p
      where p.dept_id = v_dept_id and p.is_active = true
    ), '[]'::jsonb),
    'inventory', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id,
        'dept_id', v_dept_code,
        'product_id', i.product_id,
        'item_name', i.item_name,
        'unit', i.unit,
        'quantity', i.quantity,
        'date_updated', i.updated_at
      ) order by i.item_name)
      from public.dept_inventory i
      where i.dept_id = v_dept_id
    ), '[]'::jsonb),
    'transactions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'dept_id', v_dept_code,
        'type', t.type,
        'amount', t.amount,
        'base_amount', t.base_amount,
        'honor_amount', t.honor_amount,
        'description', t.description,
        'date', t.txn_date,
        'txn_date', t.txn_date,
        'category', t.category,
        'buyer_name', t.buyer_name,
        'buyer_phone', t.buyer_phone,
        'created_at', t.created_at,
        'updated_at', t.updated_at,
        'metadata', t.metadata || jsonb_build_object(
          'honor_amount', t.honor_amount,
          'buyer_name', t.buyer_name,
          'buyer_phone', t.buyer_phone,
          'seller_name', coalesce(t.metadata->>'seller_name', case when t.type = 'expense' then t.buyer_name else null end),
          'line_items', coalesce(
            nullif(t.metadata->'line_items', '[]'::jsonb),
            (
              select jsonb_agg(jsonb_build_object(
                'product_id', ti.product_id,
                'product_name', ti.product_name,
                'name', ti.product_name,
                'unit', ti.unit,
                'qty', ti.quantity,
                'rate', ti.unit_price,
                'amount', ti.line_total
              ) order by ti.sort_order)
              from public.dept_transaction_items ti
              where ti.transaction_id = t.id
            ),
            '[]'::jsonb
          )
        )
      ) order by t.txn_date desc, t.created_at desc)
      from public.dept_transactions t
      where t.dept_id = v_dept_id and t.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.dept_rel_bootstrap(uuid, text, text) to anon;
