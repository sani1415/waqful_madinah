-- ছাত্র-বিস্তারিত মডালের মূল্যায়ন ট্যাব: দপ্তর দায়িত্বশীল (role = 'daftar') আগে
-- mdr_rel_get_student_akhlaq ডাকলে invalid_actor পেত, ফলে "হুসনুল খুলুক লোড হচ্ছে…"
-- আটকে থাকত। দপ্তর সব ছাত্রের তালিকা দেখে, তাই daftar-কে admin-এর মতো সব ছাত্রের
-- আখলাক পড়ার অনুমতি দেওয়া হলো। শিক্ষকের সীমাবদ্ধতা (শুধু নিজের ক্লাস) অপরিবর্তিত।

create or replace function public.mdr_rel_get_student_akhlaq(
  p_actor_id uuid,
  p_pin      text,
  p_student_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor public.mdr_shared_users%rowtype;
  v_student public.mdr_students%rowtype;
begin
  select * into v_actor
  from public.mdr_shared_users
  where id = p_actor_id
    and is_active = true
    and pin = p_pin
    and role in ('admin', 'restricted_admin', 'madrasa_teacher', 'daftar');

  if v_actor.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_actor');
  end if;

  select * into v_student
  from public.mdr_students
  where id = p_student_id;

  if v_student.id is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  -- Teacher: only own class
  if v_actor.role = 'madrasa_teacher' and v_student.current_class_id <> v_actor.class_id then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  return jsonb_build_object(
    'ok', true,
    'akhlaq', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',     a.id,
        'score',  a.score,
        'reason', a.reason,
        'date',   a.evaluated_at::date,
        'at',     a.evaluated_at,
        'by',     coalesce(u.name, '')
      ) order by a.evaluated_at desc), '[]'::jsonb)
      from public.mdr_akhlaq a
      left join public.mdr_shared_users u on u.id = a.evaluated_by
      where a.student_id = p_student_id
    )
  );
end;
$$;

revoke execute on function public.mdr_rel_get_student_akhlaq(uuid, text, uuid) from public, authenticated;
grant  execute on function public.mdr_rel_get_student_akhlaq(uuid, text, uuid) to anon;
;
