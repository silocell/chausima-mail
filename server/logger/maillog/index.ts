/* =====================================================================
   maillog: Maintenance -> Mail log.
   Lists what the info@ logger copied to the log mailbox (hwlsystemslogs@aol.com):
   emails received, replies sent, and the weekly washes. Same rule as the help
   desk: only the owner or an extra admin. Read-only. Email text is kept 7 days
   (the logger clears it); the full copy is always in the log mailbox.
   ===================================================================== */
import { createClient } from "jsr:@supabase/supabase-js@2";

const OWNER = "shivkforindia@gmail.com";
const SUPA = Deno.env.get("SUPABASE_URL") ?? "", SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    const db = createClient(SUPA, SERVICE, { auth: { persistSession: false } });
    const body = await req.json().catch(() => ({}));
    const { data: who } = await db.auth.getUser(auth.replace("Bearer ", ""));
    const email = String(who?.user?.email ?? "").toLowerCase();
    if (!email) return json({ error: "Sign in first." }, 401);
    let ok = email === OWNER;
    // deno-lint-ignore no-explicit-any
    if (!ok) { const { data: xs } = await db.from("extra_admins").select("*"); ok = (xs ?? []).some((r: Record<string, unknown>) => Object.values(r).some((v) => String(v).toLowerCase() === email)); }
    if (!ok) return json({ error: "Only Launchpad admins can see the mail log." }, 403);

    const action = String(body.action ?? "list");
    if (action === "list") {
      const limit = Math.min(200, Math.max(1, Number(body.limit) || 50));
      const offset = Math.max(0, Number(body.offset) || 0);
      let q = db.from("mail_log").select("id,at,kind,mail_from,mail_to,subject,received_at,aol_status,deleted_at", { count: "exact" })
        .order("at", { ascending: false }).range(offset, offset + limit - 1);
      const kind = String(body.kind ?? "");
      if (["in", "out", "wash"].includes(kind)) q = q.eq("kind", kind);
      if (body.status === "problem") q = q.in("aol_status", ["failed", "retrying"]);
      const find = String(body.q ?? "").trim().replace(/[%,()]/g, " ").slice(0, 80);
      if (find) q = q.or(`subject.ilike.%${find}%,mail_from.ilike.%${find}%,mail_to.ilike.%${find}%`);
      const { data, count, error } = await q;
      if (error) throw new Error(error.message);
      const { data: last } = await db.from("mail_log").select("at").eq("kind", "wash").order("at", { ascending: false }).limit(1);
      return json({ rows: data ?? [], total: count ?? 0, lastWash: last?.[0]?.at ?? null });
    }
    if (action === "body") {
      const { data, error } = await db.from("mail_log").select("id,body").eq("id", Number(body.id)).maybeSingle();
      if (error) throw new Error(error.message);
      if (!data) return json({ error: "No such entry." }, 404);
      return json({ body: data.body });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    console.error("maillog", e instanceof Error ? e.message : String(e));
    return json({ error: e instanceof Error ? e.message : "Something went wrong on the server." }, 500);
  }
});
