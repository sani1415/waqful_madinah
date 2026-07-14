revoke execute on function private.mdr_account_actor(uuid, text, boolean) from public, anon, authenticated;

revoke execute on function public.mdr_rel_accounts_bootstrap(uuid, text) from public, authenticated;
revoke execute on function public.mdr_rel_account_upsert_income(uuid, text, jsonb) from public, authenticated;
revoke execute on function public.mdr_rel_account_upsert_expense(uuid, text, jsonb) from public, authenticated;
revoke execute on function public.mdr_rel_account_delete_entry(uuid, text, text, text) from public, authenticated;
revoke execute on function public.mdr_rel_account_adjust_due_purchase(uuid, text, text, text, numeric) from public, authenticated;
revoke execute on function public.mdr_rel_account_record_due_payment(uuid, text, text, numeric) from public, authenticated;
revoke execute on function public.mdr_rel_account_add_category(uuid, text, text) from public, authenticated;
revoke execute on function public.mdr_rel_account_delete_category(uuid, text, text) from public, authenticated;

grant execute on function public.mdr_rel_accounts_bootstrap(uuid, text) to anon;
grant execute on function public.mdr_rel_account_upsert_income(uuid, text, jsonb) to anon;
grant execute on function public.mdr_rel_account_upsert_expense(uuid, text, jsonb) to anon;
grant execute on function public.mdr_rel_account_delete_entry(uuid, text, text, text) to anon;
grant execute on function public.mdr_rel_account_adjust_due_purchase(uuid, text, text, text, numeric) to anon;
grant execute on function public.mdr_rel_account_record_due_payment(uuid, text, text, numeric) to anon;
grant execute on function public.mdr_rel_account_add_category(uuid, text, text) to anon;
grant execute on function public.mdr_rel_account_delete_category(uuid, text, text) to anon;;
