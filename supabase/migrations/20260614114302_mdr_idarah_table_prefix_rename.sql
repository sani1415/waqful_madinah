-- Phase 2: prefix Idarah dept/khedmat/shared tables with mdr_*.
alter table if exists public.dept_departments rename to mdr_dept_departments;
alter table if exists public.dept_edit_requests rename to mdr_dept_edit_requests;
alter table if exists public.dept_extra_fields rename to mdr_dept_extra_fields;
alter table if exists public.dept_inventory rename to mdr_dept_inventory;
alter table if exists public.dept_inventory_movements rename to mdr_dept_inventory_movements;
alter table if exists public.dept_products rename to mdr_dept_products;
alter table if exists public.dept_settings rename to mdr_dept_settings;
alter table if exists public.dept_transaction_items rename to mdr_dept_transaction_items;
alter table if exists public.dept_transactions rename to mdr_dept_transactions;
alter table if exists public.khedmat_activities rename to mdr_khedmat_activities;
alter table if exists public.khedmat_activity_types rename to mdr_khedmat_activity_types;
alter table if exists public.khedmat_beneficiaries rename to mdr_khedmat_beneficiaries;
alter table if exists public.khedmat_daily_logs rename to mdr_khedmat_daily_logs;
alter table if exists public.khedmat_finance rename to mdr_khedmat_finance;
alter table if exists public.shared_messages rename to mdr_shared_messages;
alter table if exists public.shared_notifications rename to mdr_shared_notifications;
alter table if exists public.shared_push_subscriptions rename to mdr_shared_push_subscriptions;
alter table if exists public.shared_users rename to mdr_shared_users;

do $$
declare
  r record;
  def text;
  new_def text;
  tables text[] := array[
    'dept_inventory_movements','dept_transaction_items','dept_edit_requests','dept_extra_fields','dept_departments','khedmat_activity_types','khedmat_beneficiaries','khedmat_daily_logs','shared_push_subscriptions','shared_notifications','dept_inventory','dept_products','dept_settings','dept_transactions','khedmat_activities','khedmat_finance','shared_messages','shared_users'
  ];
  t text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private') and p.prokind = 'f' loop
    begin def := pg_get_functiondef(r.oid); exception when others then continue; end;
    new_def := def;
    foreach t in array tables loop
      new_def := replace(new_def, 'public.' || t, 'public.mdr_' || t);
      new_def := regexp_replace(new_def, '\m' || t || '\M', 'mdr_' || t, 'g');
      new_def := replace(new_def, 'mdr_mdr_', 'mdr_');
    end loop;
    if new_def is distinct from def then execute new_def; end if;
  end loop;
end $$;

alter function public.dept_rel_adjust_inventory(uuid, text, text, uuid, text, text, numeric, text, text) rename to mdr_dept_rel_adjust_inventory;
alter function public.dept_rel_admin_departments(text) rename to mdr_dept_rel_admin_departments;
alter function public.dept_rel_bootstrap(uuid, text, text) rename to mdr_dept_rel_bootstrap;
alter function public.dept_rel_delete_extra_field(text, text, text) rename to mdr_dept_rel_delete_extra_field;
alter function public.dept_rel_delete_inventory_item(uuid, text, text, uuid, text) rename to mdr_dept_rel_delete_inventory_item;
alter function public.dept_rel_delete_transaction(uuid, text, text, uuid) rename to mdr_dept_rel_delete_transaction;
alter function public.dept_rel_list_departments() rename to mdr_dept_rel_list_departments;
alter function public.dept_rel_remove_product(uuid, text, text, uuid, text) rename to mdr_dept_rel_remove_product;
alter function public.dept_rel_resolve_edit_request(text, uuid, text) rename to mdr_dept_rel_resolve_edit_request;
alter function public.dept_rel_save_department(text, uuid, text, text, text, boolean) rename to mdr_dept_rel_save_department;
alter function public.dept_rel_save_edit_request(uuid, text, text, uuid, text, text, jsonb, jsonb) rename to mdr_dept_rel_save_edit_request;
alter function public.dept_rel_save_extra_field(text, text, jsonb) rename to mdr_dept_rel_save_extra_field;
alter function public.dept_rel_save_product(uuid, text, text, uuid, text, text, numeric, boolean, text, numeric, uuid, boolean, boolean) rename to mdr_dept_rel_save_product;
alter function public.dept_rel_save_settings(uuid, text, text, jsonb) rename to mdr_dept_rel_save_settings;
alter function public.dept_rel_save_transaction(uuid, text, text, text, text, date, text, numeric, numeric, text, text, jsonb, jsonb) rename to mdr_dept_rel_save_transaction;
alter function public.dept_rel_update_inventory_item(uuid, text, text, uuid, text, text, numeric, text) rename to mdr_dept_rel_update_inventory_item;
alter function public.dept_rel_update_transaction(uuid, text, text, uuid, text, date, text, numeric, numeric, text, text, jsonb, jsonb) rename to mdr_dept_rel_update_transaction;
alter function public.khedmat_rel_add_activity_images(uuid, text, text, jsonb) rename to mdr_khedmat_rel_add_activity_images;
alter function public.khedmat_rel_bootstrap(uuid, text) rename to mdr_khedmat_rel_bootstrap;
alter function public.khedmat_rel_insert_activity(uuid, text, jsonb) rename to mdr_khedmat_rel_insert_activity;
alter function public.khedmat_rel_insert_daily_log(uuid, text, text, text) rename to mdr_khedmat_rel_insert_daily_log;
alter function public.khedmat_rel_insert_finance(uuid, text, jsonb) rename to mdr_khedmat_rel_insert_finance;
alter function public.khedmat_rel_upsert_activity_type(uuid, text, jsonb) rename to mdr_khedmat_rel_upsert_activity_type;
alter function public.khedmat_rel_upsert_beneficiary(uuid, text, jsonb) rename to mdr_khedmat_rel_upsert_beneficiary;;
