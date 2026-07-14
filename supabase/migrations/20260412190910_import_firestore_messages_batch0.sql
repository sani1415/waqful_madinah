INSERT INTO public.messages (id, thread_id, role, type, text, extra, is_read, sent_at)
VALUES
('PQvbsVS4By1B8jIkLtQg', '1772385676163', 'out', 'text', 'salam', '{"firestoreDocId":"PQvbsVS4By1B8jIkLtQg"}'::jsonb, true, '2026-03-03T09:12:13.925Z'::timestamptz)
ON CONFLICT (id) DO NOTHING;;
