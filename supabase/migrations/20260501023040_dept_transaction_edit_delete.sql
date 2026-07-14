alter table public.dept_transactions
add column if not exists updated_at timestamptz,
add column if not exists deleted_at timestamptz,
add column if not exists deleted_by uuid references public.shared_users(id);

create or replace function public.dept_rel_update_transaction(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text,
  p_transaction_id uuid,
  p_description text,
  p_date date,
  p_category text default null,
  p_amount numeric default 0,
  p_honor_amount numeric default 0,
  p_buyer_name text default null,
  p_buyer_phone text default null,
  p_items jsonb default '[]'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_txn public.dept_transactions%rowtype;
  v_item record;
  v_new jsonb;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;

  select t.* into v_txn
  from public.dept_transactions t
  join public.dept_departments d on d.id = t.dept_id
  where t.id = p_transaction_id and d.code = p_dept_code and t.deleted_at is null;
  if v_txn.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if v_txn.type = 'income' then
    for v_item in select * from public.dept_transaction_items where transaction_id = v_txn.id and product_id is not null loop
      perform private.dept_inventory_apply(v_txn.dept_id, v_item.product_id, v_item.product_name, v_item.unit, v_item.quantity, 'adjustment', v_txn.id, v_actor.id, 'লেনদেন এডিটের আগে পুরনো বিক্রি ফেরত');
    end loop;
  end if;

  delete from public.dept_transaction_items where transaction_id = v_txn.id;

  update public.dept_transactions
  set updated_at = now()
  where id = v_txn.id;

  v_new := public.dept_rel_save_transaction(
    p_actor_id, p_pin, p_dept_code, v_txn.type, p_description, p_date, p_category,
    p_amount, p_honor_amount, p_buyer_name, p_buyer_phone, p_items, p_metadata
  );

  if coalesce((v_new->>'ok')::boolean, false) = false then
    return v_new;
  end if;

  update public.dept_transaction_items
  set transaction_id = v_txn.id
  where transaction_id = (v_new->>'id')::uuid;

  update public.dept_transactions tgt
  set amount = src.amount,
      base_amount = src.base_amount,
      honor_amount = src.honor_amount,
      description = src.description,
      txn_date = src.txn_date,
      category = src.category,
      buyer_name = src.buyer_name,
      buyer_phone = src.buyer_phone,
      metadata = src.metadata,
      updated_at = now()
  from public.dept_transactions src
  where tgt.id = v_txn.id and src.id = (v_new->>'id')::uuid;

  update public.dept_transactions
  set deleted_at = now(), deleted_by = v_actor.id
  where id = (v_new->>'id')::uuid;

  return jsonb_build_object('ok', true, 'id', v_txn.id);
end;
$$;

grant execute on function public.dept_rel_update_transaction(uuid, text, text, uuid, text, date, text, numeric, numeric, text, text, jsonb, jsonb) to anon;

create or replace function public.dept_rel_delete_transaction(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text,
  p_transaction_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_txn public.dept_transactions%rowtype;
  v_item record;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;

  select t.* into v_txn
  from public.dept_transactions t
  join public.dept_departments d on d.id = t.dept_id
  where t.id = p_transaction_id and d.code = p_dept_code and t.deleted_at is null;
  if v_txn.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if v_txn.type = 'income' then
    for v_item in select * from public.dept_transaction_items where transaction_id = v_txn.id and product_id is not null loop
      perform private.dept_inventory_apply(v_txn.dept_id, v_item.product_id, v_item.product_name, v_item.unit, v_item.quantity, 'adjustment', v_txn.id, v_actor.id, 'লেনদেন ডিলিটের কারণে বিক্রি ফেরত');
    end loop;
  end if;

  update public.dept_transactions
  set deleted_at = now(), deleted_by = v_actor.id, updated_at = now()
  where id = v_txn.id;

  return jsonb_build_object('ok', true, 'id', v_txn.id);
end;
$$;

grant execute on function public.dept_rel_delete_transaction(uuid, text, text, uuid) to anon;

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
          'line_items', coalesce((
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
          ), '[]'::jsonb)
        )
      ) order by t.txn_date desc, t.created_at desc)
      from public.dept_transactions t
      where t.dept_id = v_dept_id and t.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.dept_rel_bootstrap(uuid, text, text) to anon;;
