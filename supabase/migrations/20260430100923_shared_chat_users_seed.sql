-- 025_shared_chat_users_seed.sql
-- Ensure every staff role that can use chat has a Supabase shared user.
-- Existing Waqf app tables are intentionally untouched.

insert into public.shared_users (name, pin, role, login_id, module_access, admin_perms, dept_code, is_active)
select v.name, v.pin, v.role, v.login_id, v.module_access, '{}'::jsonb, v.dept_code, true
from (
  values
    ('হিফজ দায়িত্বশীল', '0000', 'hifz', null, array['madrasa'], null),
    ('মাকতাবা দায়িত্বশীল', '0000', 'library', null, array['madrasa'], null),
    ('পুরনো ছাত্র দায়িত্বশীল', '0000', 'alumni_tracker', null, array['madrasa'], null),
    ('খেদমত দায়িত্বশীল', '0000', 'khedmat', null, array['khedmat'], null),
    ('কৃষি বিভাগ দায়িত্বশীল', '0000', 'dept_head', 'dept_1', array['dept'], 'dept_1'),
    ('মধু বিভাগ দায়িত্বশীল', '0000', 'dept_head', 'dept_2', array['dept'], 'dept_2'),
    ('বেকারি বিভাগ দায়িত্বশীল', '0000', 'dept_head', 'dept_3', array['dept'], 'dept_3'),
    ('সেলাই বিভাগ দায়িত্বশীল', '0000', 'dept_head', 'dept_4', array['dept'], 'dept_4')
) as v(name, pin, role, login_id, module_access, dept_code)
where not exists (
  select 1
  from public.shared_users u
  where u.role = v.role
    and coalesce(lower(u.login_id), '') = coalesce(lower(v.login_id), '')
);;
