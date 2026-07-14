-- 116 document rows
-- applied from 04-documents.sql

INSERT INTO public.documents (id, student_id, student_name, file_name, file_type, file_size, category, note, storage_path, file_url, is_read, uploaded_at)
SELECT * FROM (VALUES
('test_skip','1772384615699','x','x','',0::bigint,'general','','x',NULL,false,now())
) v(id, student_id, student_name, file_name, file_type, file_size, category, note, storage_path, file_url, is_read, uploaded_at)
WHERE false;;
