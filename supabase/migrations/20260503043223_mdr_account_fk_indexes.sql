create index if not exists mdr_account_incomes_created_by_idx
  on public.mdr_account_incomes(created_by);

create index if not exists mdr_account_expenses_created_by_idx
  on public.mdr_account_expenses(created_by);

create index if not exists mdr_account_dues_created_by_idx
  on public.mdr_account_dues(created_by);

create index if not exists mdr_account_due_payments_due_id_idx
  on public.mdr_account_due_payments(due_id);

create index if not exists mdr_account_due_payments_created_by_idx
  on public.mdr_account_due_payments(created_by);

create index if not exists mdr_account_categories_created_by_idx
  on public.mdr_account_categories(created_by);;
