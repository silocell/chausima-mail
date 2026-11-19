/* chausima-login: "Sign in with Chausima" for the Launchpad apps (not Chausima Mail itself).
   The pupil types their Chausima address and password; this checks them with Chausima Mail's own server
   (a JMAP session request, the same check the mail app does), then hands back a one-time sign-in token
   for the Launchpad. The password is never stored or logged. Accounts still need the owner's approval
   in the Launchpad as before.
   Wrong passwords are counted in the database (public.login_tries), so a restart can't reset the count
   (the old in-memory count could, which is how shiv@chausima.com was guessed on 19 Nov 2026):
     3 wrong per account every 15 minutes, 10 per account in a day, 10 per internet address every 15 minutes,
     and 40 in total an hour (so Chausima Mail never bans the server). */
import { createClient } from "jsr:@supabase/supabase-js@2";
const MAIL = "https://mail.chausima.com/.well-known/jmap";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
async function wrongSince(col: "account" | "ip" | null, val: string | null, mins: number): Promise<number> {
  let q = admin.from("login_tries").select("id", { count: "exact", head: true }).gte("at", new Date(Date.now() - mins * 60_000).toISOString());
  if (col && val) q = q.eq(col, val);
  const { count, error } = await q;
  if (error) throw error;
  return count ?? 0;
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: { email?: string; password?: string } = {}; try { body = await req.json(); } catch { /* empty */ }
  let email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  if (email && !email.includes("@")) email += "@chausima.com";
  if (!/^[a-z0-9._%+-]{1,64}@chausima\.com$/.test(email) || !password || password.length > 200)
    return json({ ok: false, reason: "Use your Chausima address (like name@chausima.com) and its password." });
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  try {
    if (await wrongSince("account", email, 15) >= 3) return json({ ok: false, reason: "Too many wrong passwords for this account. Wait 15 minutes and try again." }, 429);
    if (await wrongSince("account", email, 24 * 60) >= 10) return json({ ok: false, reason: "Too many wrong passwords for this account today. Try again tomorrow, or use another way to sign in." }, 429);
    if (await wrongSince("ip", ip, 15) >= 10) return json({ ok: false, reason: "Too many tries from this connection. Wait 15 minutes and try again." }, 429);
    if (await wrongSince(null, null, 60) >= 40) return json({ ok: false, reason: "Chausima sign-in is resting for a bit. Try again later, or use another way to sign in." }, 429);
  } catch { return json({ ok: false, reason: "Chausima sign-in can't check its limits right now, so it's closed for safety. Use another way to sign in." }, 503); }
  let good = false;
  try {
    const r = await fetch(MAIL, { headers: { Authorization: "Basic " + btoa(email + ":" + password), accept: "application/json" }, signal: AbortSignal.timeout(10_000) });
    good = r.ok; await r.body?.cancel();
    if (!r.ok && r.status !== 401 && r.status !== 403) return json({ ok: false, reason: "Chausima Mail isn't answering right now. Try again in a minute." }, 503);
  } catch { return json({ ok: false, reason: "Chausima Mail isn't answering right now. Try again in a minute." }, 503); }
  if (!good) { await admin.from("login_tries").insert({ account: email, ip }); return json({ ok: false, reason: "That Chausima address and password don't match." }); }
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email, options: { data: { provider_hint: "chausima" } } });
  const token = data?.properties?.hashed_token;
  if (error || !token) {
    const m = String(error?.message ?? "").toLowerCase();
    return json({ ok: false, reason: m.includes("database") || m.includes("not allowed") ? "This Chausima account can't use the Launchpad yet. Ask the Launchpad owner to let it in." : "Couldn't sign you in just now. Try again." });
  }
  return json({ ok: true, token_hash: token, email });
});
