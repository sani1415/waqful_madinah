DO $$
DECLARE
  v_class_id uuid;
BEGIN
  SELECT c.id
  INTO v_class_id
  FROM public.mdr_classes c
  WHERE c.code = 'kitab_y2'
    AND c.is_active = true
  LIMIT 1;

  IF v_class_id IS NULL THEN
    RAISE EXCEPTION 'kitab_y2 class not found';
  END IF;

  UPDATE public.mdr_books
     SET total_pages = 184,
         sort_order = 10
   WHERE class_id = v_class_id
     AND name = 'الطريق إلى الفقه';

  IF NOT FOUND THEN
    INSERT INTO public.mdr_books (class_id, name, total_pages, sort_order)
    VALUES (v_class_id, 'الطريق إلى الفقه', 184, 10);
  END IF;

  UPDATE public.mdr_books
     SET total_pages = 361,
         sort_order = 20
   WHERE class_id = v_class_id
     AND name = 'الطريق إلى القرآن جـ1';

  IF NOT FOUND THEN
    INSERT INTO public.mdr_books (class_id, name, total_pages, sort_order)
    VALUES (v_class_id, 'الطريق إلى القرآن جـ1', 361, 20);
  END IF;

  UPDATE public.mdr_books
     SET total_pages = 191,
         sort_order = 30
   WHERE class_id = v_class_id
     AND name = 'الطريق إلى النحو';

  IF NOT FOUND THEN
    INSERT INTO public.mdr_books (class_id, name, total_pages, sort_order)
    VALUES (v_class_id, 'الطريق إلى النحو', 191, 30);
  END IF;

  UPDATE public.mdr_books
     SET total_pages = 89,
         sort_order = 40
   WHERE class_id = v_class_id
     AND name = 'القراءة الراشدة جـ1';

  IF NOT FOUND THEN
    INSERT INTO public.mdr_books (class_id, name, total_pages, sort_order)
    VALUES (v_class_id, 'القراءة الراشدة جـ1', 89, 40);
  END IF;

  UPDATE public.mdr_books
     SET total_pages = 221,
         sort_order = 50
   WHERE class_id = v_class_id
     AND name = 'قصص النبيين للأطفال جـ2';

  IF NOT FOUND THEN
    INSERT INTO public.mdr_books (class_id, name, total_pages, sort_order)
    VALUES (v_class_id, 'قصص النبيين للأطفال جـ2', 221, 50);
  END IF;
END $$;;
