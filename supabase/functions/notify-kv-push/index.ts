import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import webPush from "npm:web-push@3.6.7";

const MAILTO = Deno.env.get("WEB_PUSH_CONTACT") || "mailto:admin@localhost";

function jsonResponse(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

type SubJson = { endpoint?: string; keys?: { p256dh?: string; auth?: string } };

function pickSubscription(v: unknown): SubJson | null {
  if (!v || typeof v !== "object") return null;
  const o = v as { subscription?: SubJson; endpoint?: string; keys?: unknown };
  // waqf_pwa_subscriptions table: { subscription: { endpoint, keys } }
  if (o.subscription && typeof (o.subscription as SubJson).endpoint === "string") return o.subscription as SubJson;
  // waqf_app_kv legacy: value is the subscription object directly or wrapped
  if (typeof o.endpoint === "string" && o.endpoint.length > 0) return o as SubJson;
  return null;
}

async function sendPush(sub: SubJson, payload: string, vapidPublic: string, vapidPrivate: string) {
  webPush.setVapidDetails(MAILTO, vapidPublic, vapidPrivate);
  await webPush.sendNotification(
    sub as Parameters<typeof webPush.sendNotification>[0],
    payload,
    { TTL: 3600, urgency: "high" }
  );
}

function makePayload(body: string, target: "teacher" | "student", tag: string): string {
  return JSON.stringify({
    title: "Waqful Madinah",
    body,
    url: target === "teacher" ? "/teacher/" : "/student/",
    icon: target === "teacher" ? "icons/icon-teacher-192.png" : "icons/icon-student-192.png",
    tag,
  });
}

// ── Subscription lookup from waqf_pwa_subscriptions + waqf_app_kv fallback ──
async function getTeacherSub(sb: ReturnType<typeof createClient>): Promise<SubJson | null> {
  // Try waqf_pwa_subscriptions first
  const { data: rel } = await sb
    .from("waqf_pwa_subscriptions").select("subscription").eq("id", "teacher").maybeSingle();
  if (rel?.subscription) {
    const s = pickSubscription({ subscription: rel.subscription });
    if (s) return s;
  }
  // Fallback: waqf_app_kv
  const { data: kv } = await sb
    .from("waqf_app_kv").select("value").eq("key", "pwa_push_teacher").maybeSingle();
  return kv?.value ? pickSubscription(kv.value) : null;
}

async function getAllStudentSubs(sb: ReturnType<typeof createClient>): Promise<SubJson[]> {
  const subs: SubJson[] = [];
  // New table
  const { data: relRows } = await sb
    .from("waqf_pwa_subscriptions").select("id, subscription").eq("role", "student");
  for (const row of relRows || []) {
    if (String(row.id || "").startsWith("shared_device_")) continue;
    const s = pickSubscription({ subscription: row.subscription });
    if (s) subs.push(s);
  }
  // waqf_app_kv fallback (deduplicate by endpoint)
  const endpoints = new Set(subs.map((s) => s.endpoint));
  const { data: kvRows } = await sb
    .from("waqf_app_kv").select("value").like("key", "pwa_push_student_%");
  for (const row of kvRows || []) {
    const s = pickSubscription(row.value);
    if (s && s.endpoint && !endpoints.has(s.endpoint)) { subs.push(s); endpoints.add(s.endpoint); }
  }
  return subs;
}

async function getStudentSubByWaqf(sb: ReturnType<typeof createClient>, waqfId: string): Promise<SubJson | null> {
  const { data: rel } = await sb
    .from("waqf_pwa_subscriptions").select("subscription").eq("id", waqfId).maybeSingle();
  if (rel?.subscription) {
    const s = pickSubscription({ subscription: rel.subscription });
    if (s) return s;
  }
  const { data: kv } = await sb
    .from("waqf_app_kv").select("value").eq("key", `pwa_push_student_${waqfId}`).maybeSingle();
  return kv?.value ? pickSubscription(kv.value) : null;
}

async function getAllSharedDeviceSubs(sb: ReturnType<typeof createClient>): Promise<SubJson[]> {
  // All rows whose id starts with 'shared_device_' are shared physical devices
  const { data: rows } = await sb
    .from("waqf_pwa_subscriptions").select("subscription").like("id", "shared_device_%");
  const subs: SubJson[] = [];
  for (const row of rows || []) {
    const s = pickSubscription({ subscription: row.subscription });
    if (s) subs.push(s);
  }
  return subs;
}

// ── Main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  const secret = (Deno.env.get("NOTIFY_WEBHOOK_SECRET") || "").trim();
  const auth = req.headers.get("authorization") || "";
  const hdr = (req.headers.get("x-notify-secret") || "").trim();
  const bearer = secret ? `Bearer ${secret}` : "";
  if (!secret || (auth !== bearer && hdr !== secret)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const vapidPublic = (Deno.env.get("VAPID_PUBLIC_KEY") || "").trim();
  const vapidPrivate = (Deno.env.get("VAPID_PRIVATE_KEY") || "").trim();
  if (!vapidPublic || !vapidPrivate) {
    return jsonResponse({ error: "vapid_not_configured" }, 500);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return jsonResponse({ error: "invalid_json" }, 400); }

  const table = String(body.table || "");
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(supabaseUrl, serviceKey);

  let sent = 0, failed = 0;
  const staleEndpoints: string[] = [];

  async function trySend(sub: SubJson, payload: string) {
    try {
      await sendPush(sub, payload, vapidPublic, vapidPrivate);
      sent++;
      console.log("push ok", sub.endpoint?.slice(-30));
    } catch (e: unknown) {
      const status = (e as { statusCode?: number })?.statusCode;
      console.error("push failed", status, sub.endpoint?.slice(-30), String(e));
      failed++;
      // 410 Gone or 404 = subscription expired/invalid — mark for removal
      if (status === 410 || status === 404) {
        if (sub.endpoint) staleEndpoints.push(sub.endpoint);
      }
    }
  }

  async function removeStaleSubscriptions() {
    if (!staleEndpoints.length) return;
    for (const ep of staleEndpoints) {
      await sb.from("waqf_pwa_subscriptions").delete()
        .filter("subscription->>'endpoint'", "eq", ep);
    }
    console.log("removed stale subs:", staleEndpoints.length);
  }

  // ── waqf_messages table webhook ───────────────────────────────
  if (table === "waqf_messages") {
    const record = body.record as Record<string, unknown> | undefined;
    if (!record) return jsonResponse({ ok: true, skipped: "no_record" });

    const msgRole = String(record.role || "");   // 'in' = student→teacher, 'out' = teacher→student
    const threadId = String(record.thread_id || "");

    if (msgRole === "in") {
      // Student sent a message → notify teacher (tag per thread so each student stacks separately)
      const { data: stuInfo } = await sb
        .from("waqf_students").select("name").eq("id", threadId).maybeSingle();
      const studentName = stuInfo?.name ? String(stuInfo.name) : "ছাত্র";
      const teacherSub = await getTeacherSub(sb);
      if (teacherSub) await trySend(teacherSub,
        makePayload(`${studentName}: নতুন বার্তা পাঠিয়েছে।`, "teacher", `msg-in-${threadId}`));
    } else if (msgRole === "out") {
      if (threadId === "_bc") {
        // Broadcast → notify all students once per unique endpoint
        const allSubs = await getAllStudentSubs(sb);
        const bcSentEndpoints = new Set<string>();
        for (const sub of allSubs) {
          if (sub.endpoint && bcSentEndpoints.has(sub.endpoint)) continue;
          await trySend(sub, makePayload("জিম্মাদারের নতুন বার্তা এসেছে।", "student", "msg-out-bc"));
          if (sub.endpoint) bcSentEndpoints.add(sub.endpoint);
        }
      } else {
        // Skip student-thread copies of broadcast messages — notification already sent via _bc row
        const extra = record.extra as Record<string, unknown> | null;
        if (extra?.bc_copy) return jsonResponse({ ok: true, skipped: "bc_copy" });
        // Teacher → specific student: look up student's name and waqf_id
        const { data: stu } = await sb
          .from("waqf_students").select("name, waqf_id").eq("id", threadId).maybeSingle();
        const waqfId = stu?.waqf_id ? String(stu.waqf_id) : null;
        const studentName = stu?.name ? String(stu.name) : null;
        const msgBody = studentName
          ? `${studentName}, জিম্মাদারের নতুন বার্তা এসেছে।`
          : "জিম্মাদারের নতুন বার্তা এসেছে।";
        // Collect all endpoints to avoid duplicate pushes
        const sentEndpoints = new Set<string>();

        if (waqfId) {
          // Notify the student's personal device (if subscribed individually)
          const personalSub = await getStudentSubByWaqf(sb, waqfId);
          if (personalSub?.endpoint) {
            await trySend(personalSub, makePayload(msgBody, "student", `msg-out-${waqfId}`));
            sentEndpoints.add(personalSub.endpoint);
          }
        }
      }
    }

    await removeStaleSubscriptions();
    return jsonResponse({ ok: true, table: "waqf_messages", sent, failed });
  }

  // ── waqf_app_kv webhook (kept for transition period) ──────────
  if (table !== "waqf_app_kv") return jsonResponse({ ok: true, skipped: "unknown_table" });

  const record = body.record as Record<string, unknown> | undefined;
  const key = record?.key != null ? String(record.key) : "";

  // Skip subscription keys — they are not data events
  if (key === "pwa_push_teacher" || key.startsWith("pwa_push_student_")) {
    return jsonResponse({ ok: true, skipped: "subscription_key" });
  }
  // Only notify on 'core' (chat messages marked with _notifyAt)
  if (key !== "core") return jsonResponse({ ok: true, skipped: "non_chat_key" });

  const oldVal = (body.old_record as Record<string, unknown> | undefined)?.value as Record<string, unknown> | undefined;
  const newVal = record?.value as Record<string, unknown> | undefined;
  if (!newVal?._notifyAt || newVal._notifyAt === oldVal?._notifyAt) {
    return jsonResponse({ ok: true, skipped: "no_notify_event" });
  }

  const teacherSub = await getTeacherSub(sb);
  const allStudentSubs = await getAllStudentSubs(sb);
  const teacherEndpoint = teacherSub?.endpoint ?? null;
  const dedupedStudentSubs = allStudentSubs.filter(
    (s) => !teacherEndpoint || s.endpoint !== teacherEndpoint
  );

  for (const sub of dedupedStudentSubs)
    await trySend(sub, makePayload("জিম্মাদারের নতুন আপডেট এসেছে। অ্যাপ খুলুন।", "student", `kv-student-${key}`));
  if (teacherSub)
    await trySend(teacherSub, makePayload("ছাত্রের নতুন আপডেট এসেছে।", "teacher", `kv-teacher-${key}`));

  await removeStaleSubscriptions();
  return jsonResponse({ ok: true, table: "waqf_app_kv", sent, failed,
    teacher_targets: teacherSub ? 1 : 0,
    student_targets: dedupedStudentSubs.length });
});
