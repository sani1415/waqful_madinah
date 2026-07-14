-- 030_dept_sales_inventory.sql
-- Department products, sales/expenses, inventory movements, and RPCs.

create table if not exists public.dept_products (
  id uuid primary key default gen_random_uuid(),
  dept_id uuid not null references public.dept_departments(id) on delete cascade,
  name text not null,
  unit text not null default 'পিস',
  price numeric(12,2) not null default 0 check (price >= 0),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists dept_products_dept_name_key
on public.dept_products (dept_id, lower(name));

create table if not exists public.dept_transactions (
  id uuid primary key default gen_random_uuid(),
  dept_id uuid not null references public.dept_departments(id) on delete cascade,
  type text not null check (type in ('income', 'expense')),
  amount numeric(12,2) not null check (amount >= 0),
  base_amount numeric(12,2) not null default 0 check (base_amount >= 0),
  honor_amount numeric(12,2) not null default 0 check (honor_amount >= 0),
  description text not null default '',
  txn_date date not null default current_date,
  category text,
  buyer_name text,
  buyer_phone text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references public.shared_users(id),
  created_at timestamptz not null default now()
);

create index if not exists dept_transactions_dept_date_idx
on public.dept_transactions (dept_id, txn_date desc);

create table if not exists public.dept_transaction_items (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.dept_transactions(id) on delete cascade,
  product_id uuid references public.dept_products(id),
  product_name text not null,
  unit text,
  quantity numeric(12,3) not null default 0 check (quantity >= 0),
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  line_total numeric(12,2) not null default 0 check (line_total >= 0),
  sort_order integer not null default 0
);

create table if not exists public.dept_inventory (
  id uuid primary key default gen_random_uuid(),
  dept_id uuid not null references public.dept_departments(id) on delete cascade,
  product_id uuid references public.dept_products(id),
  item_name text not null,
  unit text not null default 'পিস',
  quantity numeric(12,3) not null default 0,
  updated_at timestamptz not null default now()
);

create unique index if not exists dept_inventory_product_key
on public.dept_inventory (dept_id, product_id)
where product_id is not null;

create unique index if not exists dept_inventory_item_key
on public.dept_inventory (dept_id, lower(item_name), lower(unit))
where product_id is null;

create table if not exists public.dept_inventory_movements (
  id uuid primary key default gen_random_uuid(),
  dept_id uuid not null references public.dept_departments(id) on delete cascade,
  product_id uuid references public.dept_products(id),
  transaction_id uuid references public.dept_transactions(id) on delete set null,
  item_name text not null,
  unit text not null default 'পিস',
  quantity_delta numeric(12,3) not null,
  reason text not null check (reason in ('stock_in', 'sale', 'waste', 'adjustment')),
  notes text,
  created_by uuid references public.shared_users(id),
  created_at timestamptz not null default now()
);

alter table public.dept_products enable row level security;
alter table public.dept_transactions enable row level security;
alter table public.dept_transaction_items enable row level security;
alter table public.dept_inventory enable row level security;
alter table public.dept_inventory_movements enable row level security;

drop policy if exists "deny_all_dept_products" on public.dept_products;
create policy "deny_all_dept_products" on public.dept_products for all using (false) with check (false);
drop policy if exists "deny_all_dept_transactions" on public.dept_transactions;
create policy "deny_all_dept_transactions" on public.dept_transactions for all using (false) with check (false);
drop policy if exists "deny_all_dept_transaction_items" on public.dept_transaction_items;
create policy "deny_all_dept_transaction_items" on public.dept_transaction_items for all using (false) with check (false);
drop policy if exists "deny_all_dept_inventory" on public.dept_inventory;
create policy "deny_all_dept_inventory" on public.dept_inventory for all using (false) with check (false);
drop policy if exists "deny_all_dept_inventory_movements" on public.dept_inventory_movements;
create policy "deny_all_dept_inventory_movements" on public.dept_inventory_movements for all using (false) with check (false);

insert into public.dept_departments (name, code, emoji, sort_order) values
  ('স্টোর',       'dept_5', '📦', 5),
  ('রান্নাঘর',    'dept_6', '🍽️', 6),
  ('বই বিতরণ',    'dept_7', '📚', 7)
on conflict (code) do nothing;

update public.dept_departments
set emoji = '✂️'
where code = 'dept_4' and emoji in ('🧵', '🏢', '');

with seed(code, name, unit, price, sort_order) as (
  values
    ('dept_1', 'লাল শাক', 'কেজি', 30, 1),
    ('dept_1', 'পালং শাক', 'কেজি', 35, 2),
    ('dept_1', 'লাউ', 'পিস', 60, 3),
    ('dept_1', 'ধান', 'কেজি', 32, 4),
    ('dept_1', 'মরিচ', 'কেজি', 120, 5),
    ('dept_2', 'কাঁচা মধু', 'কেজি', 650, 1),
    ('dept_2', 'প্রক্রিয়াজাত মধু', 'কেজি', 750, 2),
    ('dept_2', 'মোম', 'কেজি', 300, 3),
    ('dept_3', 'রুটি', 'পিস', 10, 1),
    ('dept_3', 'বিস্কুট', 'প্যাকেট', 40, 2),
    ('dept_3', 'কেক', 'পিস', 80, 3),
    ('dept_4', 'পাঞ্জাবি', 'পিস', 850, 1),
    ('dept_4', 'টুপি', 'পিস', 80, 2),
    ('dept_4', 'ব্যাগ', 'পিস', 250, 3),
    ('dept_5', 'চাল', 'কেজি', 70, 1),
    ('dept_5', 'ডাল', 'কেজি', 120, 2),
    ('dept_5', 'তেল', 'লিটার', 170, 3),
    ('dept_6', 'রান্না করা ভাত', 'প্লেট', 50, 1),
    ('dept_6', 'সবজি', 'প্লেট', 30, 2),
    ('dept_6', 'নাস্তা', 'পিস', 20, 3),
    ('dept_7', 'খাতা', 'পিস', 40, 1),
    ('dept_7', 'কলম', 'পিস', 10, 2),
    ('dept_7', 'কিতাব', 'পিস', 200, 3)
)
insert into public.dept_products (dept_id, name, unit, price, sort_order)
select d.id, s.name, s.unit, s.price, s.sort_order
from seed s
join public.dept_departments d on d.code = s.code
on conflict (dept_id, lower(name)) do update
set unit = excluded.unit,
    price = excluded.price,
    is_active = true,
    sort_order = excluded.sort_order,
    updated_at = now();

create or replace function private.dept_authorized_actor(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text default null
)
returns public.shared_users
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
begin
  select * into v_actor
  from public.shared_users
  where id = p_actor_id
    and pin = p_pin
    and is_active = true
    and role = 'dept_head'
    and (p_dept_code is null or dept_code = p_dept_code);

  return v_actor;
end;
$$;

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
begin
  if p_product_id is not null then
    insert into public.dept_inventory (dept_id, product_id, item_name, unit, quantity, updated_at)
    values (p_dept_id, p_product_id, btrim(p_item_name), coalesce(nullif(btrim(p_unit), ''), 'পিস'), p_delta, now())
    on conflict (dept_id, product_id) where product_id is not null
    do update set
      item_name = excluded.item_name,
      unit = excluded.unit,
      quantity = public.dept_inventory.quantity + excluded.quantity,
      updated_at = now();
  else
    insert into public.dept_inventory (dept_id, product_id, item_name, unit, quantity, updated_at)
    values (p_dept_id, null, btrim(p_item_name), coalesce(nullif(btrim(p_unit), ''), 'পিস'), p_delta, now())
    on conflict (dept_id, lower(item_name), lower(unit)) where product_id is null
    do update set
      quantity = public.dept_inventory.quantity + excluded.quantity,
      updated_at = now();
  end if;

  insert into public.dept_inventory_movements (
    dept_id, product_id, transaction_id, item_name, unit, quantity_delta, reason, notes, created_by
  )
  values (
    p_dept_id, p_product_id, p_transaction_id, btrim(p_item_name),
    coalesce(nullif(btrim(p_unit), ''), 'পিস'), p_delta, p_reason, p_notes, p_created_by
  );
end;
$$;

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
      where t.dept_id = v_dept_id
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.dept_rel_bootstrap(uuid, text, text) to anon;

create or replace function public.dept_rel_save_product(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text,
  p_product_id uuid,
  p_name text,
  p_unit text,
  p_price numeric,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_dept_id uuid;
  v_product_id uuid;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;

  select id into v_dept_id from public.dept_departments where code = p_dept_code and is_active = true;
  if v_dept_id is null then
    return jsonb_build_object('ok', false, 'error', 'dept_not_found');
  end if;

  if p_product_id is null then
    insert into public.dept_products (dept_id, name, unit, price)
    values (v_dept_id, btrim(p_name), coalesce(nullif(btrim(p_unit), ''), 'পিস'), greatest(coalesce(p_price, 0), 0))
    on conflict (dept_id, lower(name)) do update
    set unit = excluded.unit,
        price = excluded.price,
        is_active = p_is_active,
        updated_at = now()
    returning id into v_product_id;
  else
    update public.dept_products
    set name = btrim(p_name),
        unit = coalesce(nullif(btrim(p_unit), ''), 'পিস'),
        price = greatest(coalesce(p_price, 0), 0),
        is_active = p_is_active,
        updated_at = now()
    where id = p_product_id and dept_id = v_dept_id
    returning id into v_product_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_product_id);
end;
$$;

grant execute on function public.dept_rel_save_product(uuid, text, text, uuid, text, text, numeric, boolean) to anon;

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
  if btrim(coalesce(p_description, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'description_required');
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
    v_base := greatest(coalesce(p_amount, 0), 0);
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
    btrim(p_description), coalesce(p_date, current_date),
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

grant execute on function public.dept_rel_save_transaction(uuid, text, text, text, text, date, text, numeric, numeric, text, text, jsonb, jsonb) to anon;

create or replace function public.dept_rel_adjust_inventory(
  p_actor_id uuid,
  p_pin text,
  p_dept_code text,
  p_product_id uuid,
  p_item_name text,
  p_unit text,
  p_quantity_delta numeric,
  p_reason text default 'stock_in',
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.shared_users%rowtype;
  v_dept_id uuid;
  v_product public.dept_products%rowtype;
  v_name text;
  v_unit text;
begin
  v_actor := private.dept_authorized_actor(p_actor_id, p_pin, p_dept_code);
  if v_actor.id is null and not private.verify_admin_pin(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'invalid_login');
  end if;
  if p_reason not in ('stock_in', 'waste', 'adjustment') then
    return jsonb_build_object('ok', false, 'error', 'invalid_reason');
  end if;
  if coalesce(p_quantity_delta, 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'quantity_required');
  end if;

  select id into v_dept_id from public.dept_departments where code = p_dept_code and is_active = true;
  if v_dept_id is null then
    return jsonb_build_object('ok', false, 'error', 'dept_not_found');
  end if;

  if p_product_id is not null then
    select * into v_product from public.dept_products where id = p_product_id and dept_id = v_dept_id;
  end if;
  v_name := coalesce(v_product.name, nullif(btrim(coalesce(p_item_name, '')), ''));
  v_unit := coalesce(v_product.unit, nullif(btrim(coalesce(p_unit, '')), ''), 'পিস');
  if v_name is null or v_name = '' then
    return jsonb_build_object('ok', false, 'error', 'item_required');
  end if;

  perform private.dept_inventory_apply(
    v_dept_id,
    v_product.id,
    v_name,
    v_unit,
    p_quantity_delta,
    p_reason,
    null,
    v_actor.id,
    p_notes
  );

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.dept_rel_adjust_inventory(uuid, text, text, uuid, text, text, numeric, text, text) to anon;;
