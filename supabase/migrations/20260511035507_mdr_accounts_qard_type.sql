-- Step 1: expenses CHECK constraint তে qard যোগ
ALTER TABLE public.mdr_account_expenses
  DROP CONSTRAINT mdr_account_expenses_account_check;
ALTER TABLE public.mdr_account_expenses
  ADD CONSTRAINT mdr_account_expenses_account_check
  CHECK (account = ANY (ARRAY['matbakh'::text, 'madrasa'::text, 'tamirat'::text, 'general'::text, 'qard'::text]));

-- Step 2: incomes CHECK constraint তে qard_return যোগ
ALTER TABLE public.mdr_account_incomes
  DROP CONSTRAINT mdr_account_incomes_account_check;
ALTER TABLE public.mdr_account_incomes
  ADD CONSTRAINT mdr_account_incomes_account_check
  CHECK (account = ANY (ARRAY['matbakh'::text, 'madrasa'::text, 'tamirat'::text, 'general'::text, 'qard_return'::text]));

-- Step 3: সব general expense কে qard-এ রূপান্তর
UPDATE public.mdr_account_expenses
  SET account = 'qard',
      updated_at = now()
  WHERE account = 'general';;
