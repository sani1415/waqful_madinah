-- Department inventory guard: sale/waste cannot make stock negative.

create or replace function private.dept_inventory_apply(
  p_dept_id uuid,
  p_product_id uuid,
  p_item_name text,
  p_unit text,
  p_delta numeric,
  p_reason text,
  p_transaction_id uuid,
  p_created_by uuid,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_name text := btrim(coalesce(p_item_name, ''));
  v_unit text := coalesce(nullif(btrim(p_unit), ''), 'পিস');
  v_next numeric;
begin
  if p_delta < 0 then
    if p_product_id is not null then
      select quantity + p_delta into v_next
      from public.dept_inventory
      where dept_id = p_dept_id and product_id = p_product_id
      for update;
    else
      select quantity + p_delta into v_next
      from public.dept_inventory
      where dept_id = p_dept_id
        and product_id is null
        and lower(item_name) = lower(v_name)
        and lower(unit) = lower(v_unit)
      for update;
    end if;

    if v_next is null or v_next < 0 then
      raise exception 'insufficient_stock';
    end if;
  end if;

  if p_product_id is not null then
    insert into public.dept_inventory (dept_id, product_id, item_name, unit, quantity, updated_at)
    values (p_dept_id, p_product_id, v_name, v_unit, p_delta, now())
    on conflict (dept_id, product_id) where product_id is not null
    do update set
      item_name = excluded.item_name,
      unit = excluded.unit,
      quantity = public.dept_inventory.quantity + excluded.quantity,
      updated_at = now();
  else
    insert into public.dept_inventory (dept_id, product_id, item_name, unit, quantity, updated_at)
    values (p_dept_id, null, v_name, v_unit, p_delta, now())
    on conflict (dept_id, lower(item_name), lower(unit)) where product_id is null
    do update set
      quantity = public.dept_inventory.quantity + excluded.quantity,
      updated_at = now();
  end if;

  insert into public.dept_inventory_movements (
    dept_id, product_id, transaction_id, item_name, unit, quantity_delta, reason, notes, created_by
  )
  values (
    p_dept_id, p_product_id, p_transaction_id, v_name, v_unit, p_delta, p_reason, p_notes, p_created_by
  );
end;
$$;
