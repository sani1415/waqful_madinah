DROP INDEX IF EXISTS public.students_pin_idx;

UPDATE public.students SET pin = '1234' WHERE pin IS DISTINCT FROM '1234';;
