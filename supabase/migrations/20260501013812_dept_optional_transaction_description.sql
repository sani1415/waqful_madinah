create or replace function public.dept_rel_save_transaction(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text,
  p_type text,
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
  v_dept_id uuid;
  v_txn_id uuid;
  v_items jsonb := coalesce(p_items, '[]'::jsonb);
  v_base numeric := 0;
  v_amount numeric := 0;
  v_item jsonb;
  v_product public.dept_products%rowtype;
  v_name text;
  v_unit text;
  v_qty numeric;
  v_rate numeric;
  v_line_total numeric;
  v_sort integer := 0;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;
  if p_type not in ('income', 'expense') then
    return jsonb_build_object('ok', false, 'error', 'invalid_type');
  end if;

  select id into v_dept_id from public.dept_departments where code = p_dept_code and is_active = true;
  if v_dept_id is null then
    return jsonb_build_object('ok', false, 'error', 'dept_not_found');
  end if;

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_qty := greatest(coalesce((v_item->>'qty')::numeric, (v_item->>'quantity')::numeric, 1), 0);
    v_rate := greatest(coalesce((v_item->>'rate')::numeric, (v_item->>'unit_price')::numeric, (v_item->>'amount')::numeric, 0), 0);
    if p_type = 'income' then
      v_line_total := greatest(coalesce((v_item->>'amount')::numeric, v_qty * v_rate), 0);
    else
      v_line_total := greatest(coalesce((v_item->>'amount')::numeric, 0), 0);
    end if;
    v_base := v_base + v_line_total;
  end loop;

  if v_base <= 0 then
    v_base := greatest(
      coalesce(p_amount, 0) - case when p_type = 'income' then greatest(coalesce(p_honor_amount, 0), 0) else 0 end,
      0
    );
  end if;
  v_amount := v_base + case when p_type = 'income' then greatest(coalesce(p_honor_amount, 0), 0) else 0 end;

  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'error', 'amount_required');
  end if;

  insert into public.dept_transactions (
    dept_id, type, amount, base_amount, honor_amount, description, txn_date,
    category, buyer_name, buyer_phone, metadata, created_by
  )
  values (
    v_dept_id, p_type, v_amount, v_base,
    case when p_type = 'income' then greatest(coalesce(p_honor_amount, 0), 0) else 0 end,
    btrim(coalesce(p_description, '')), coalesce(p_date, current_date),
    p_category, nullif(btrim(coalesce(p_buyer_name, '')), ''),
    nullif(btrim(coalesce(p_buyer_phone, '')), ''),
    coalesce(p_metadata, '{}'::jsonb), v_actor.id
  )
  returning id into v_txn_id;

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_sort := v_sort + 1;
    v_product := null;
    if nullif(v_item->>'product_id', '') is not null then
      select * into v_product
      from public.dept_products
      where id = (v_item->>'product_id')::uuid and dept_id = v_dept_id;
    end if;

    v_name := coalesce(nullif(v_item->>'product_name', ''), nullif(v_item->>'name', ''), v_product.name, 'আইটেম');
    v_unit := coalesce(nullif(v_item->>'unit', ''), v_product.unit, 'পিস');
    v_qty := greatest(coalesce((v_item->>'qty')::numeric, (v_item->>'quantity')::numeric, case when p_type = 'income' then 0 else 1 end), 0);
    v_rate := greatest(coalesce((v_item->>'rate')::numeric, (v_item->>'unit_price')::numeric, case when v_qty > 0 then (v_item->>'amount')::numeric / v_qty else 0 end, 0), 0);
    v_line_total := greatest(coalesce((v_item->>'amount')::numeric, case when p_type = 'income' then v_qty * v_rate else v_rate end), 0);

    insert into public.dept_transaction_items (
      transaction_id, product_id, product_name, unit, quantity, unit_price, line_total, sort_order
    )
    values (
      v_txn_id, v_product.id, v_name, v_unit, v_qty,
      case when p_type = 'income' then v_rate else v_line_total end,
      v_line_total, v_sort
    );

    if p_type = 'income' and v_product.id is not null and v_qty > 0 then
      perform private.dept_inventory_apply(
        v_dept_id, v_product.id, v_name, v_unit, -v_qty, 'sale', v_txn_id, v_actor.id, 'বিক্রির কারণে মজুদ কমেছে'
      );
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'id', v_txn_id);
end;
$$;

grant execute on function public.dept_rel_save_transaction(uuid, text, text, text, text, date, text, numeric, numeric, text, text, jsonb, jsonb) to anon;;
