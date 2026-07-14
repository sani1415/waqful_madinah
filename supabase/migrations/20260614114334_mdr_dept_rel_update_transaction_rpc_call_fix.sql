CREATE OR REPLACE FUNCTION public.mdr_dept_rel_update_transaction(p_actor_id uuid, p_pin text, p_dept_code text, p_transaction_id uuid, p_description text, p_date date, p_category text DEFAULT NULL::text, p_amount numeric DEFAULT 0, p_honor_amount numeric DEFAULT 0, p_buyer_name text DEFAULT NULL::text, p_buyer_phone text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_txn public.mdr_dept_transactions%rowtype;
  v_item record;
  v_product public.mdr_dept_products%rowtype;
  v_stock_product public.mdr_dept_products%rowtype;
  v_stock_unit text;
  v_stock_qty numeric;
  v_new jsonb;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;

  select t.* into v_txn
  from public.mdr_dept_transactions t
  join public.mdr_dept_departments d on d.id = t.dept_id
  where t.id = p_transaction_id and d.code = p_dept_code and t.deleted_at is null;
  if v_txn.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if v_txn.type = 'income' then
    for v_item in select * from public.mdr_dept_transaction_items where transaction_id = v_txn.id and product_id is not null loop
      select * into v_product from public.mdr_dept_products where id = v_item.product_id;
      if v_product.id is not null and v_product.stock_product_id is not null then
        select * into v_stock_product from public.mdr_dept_products where id = v_product.stock_product_id;
      else
        v_stock_product := v_product;
      end if;
      v_stock_unit := coalesce(nullif(btrim(v_stock_product.stock_unit), ''), v_stock_product.unit, v_product.stock_unit, v_product.unit, 'পিস');
      v_stock_qty := private.dept_convert_qty_to_stock_unit(
        v_item.quantity, v_item.unit, v_stock_unit, v_product.unit, v_product.pack_size
      );
      perform private.dept_inventory_apply(
        v_txn.dept_id, v_stock_product.id, coalesce(v_stock_product.name, v_item.product_name), v_stock_unit, v_stock_qty,
        'adjustment', v_txn.id, v_actor.id, 'লেনদেন এডিটের আগে পুরনো বিক্রি ফেরত'
      );
    end loop;
  end if;

  delete from public.mdr_dept_transaction_items where transaction_id = v_txn.id;

  update public.mdr_dept_transactions
  set description = btrim(coalesce(p_description, '')),
      txn_date = coalesce(p_date, current_date),
      category = p_category,
      amount = 0,
      base_amount = 0,
      honor_amount = case when v_txn.type = 'income' then greatest(coalesce(p_honor_amount, 0), 0) else 0 end,
      buyer_name = nullif(btrim(coalesce(p_buyer_name, '')), ''),
      buyer_phone = nullif(btrim(coalesce(p_buyer_phone, '')), ''),
      metadata = coalesce(p_metadata, '{}'::jsonb),
      updated_at = now()
  where id = v_txn.id;

  v_new := public.mdr_dept_rel_save_transaction(
    p_actor_id, p_pin, p_dept_code, v_txn.type, p_description, p_date, p_category,
    p_amount, p_honor_amount, p_buyer_name, p_buyer_phone, p_items, p_metadata
  );

  update public.mdr_dept_transaction_items
  set transaction_id = v_txn.id
  where transaction_id = (v_new->>'id')::uuid;

  update public.mdr_dept_transactions src
  set deleted_at = now(), deleted_by = v_actor.id
  where src.id = (v_new->>'id')::uuid;

  update public.mdr_dept_transactions tgt
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
  from public.mdr_dept_transactions src
  where tgt.id = v_txn.id and src.id = (v_new->>'id')::uuid;

  return jsonb_build_object('ok', true, 'id', v_txn.id);
end;
$function$;;
