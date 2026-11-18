/* chausima-login: "Sign in with Chausima" for the Launchpad apps (not Chausima Mail itself).
   The pupil types their Chausima address and password; this checks them with Chausima Mail's own server
   (a JMAP session request, the same check the mail app does), then hands back a one-time sign-in token
   for the Launchpad. The password is never stored or logged. Accounts still need the owner's approval
   in the Launchpad as before. Limits: 5 tries per address and 20 per connection every 15 minutes, and at
   most 40 wrong passwords an hour in total, so Chausima Mail never bans the server for too many failures. */
import { createClient } from "jsr:@supabase/supabase-js@2";
const MAIL = "https://mail.chausima.com/.well-known/jmap";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });
const W = 15 * 60_000;
const tries = new Map<string, number[]>();
let fails: number[] = [];
function hit(k: string, max: number): boolean {
  const now = Date.now(), a = (tries.get(k) ?? []).filter((t) => now - t < W);
  a.push(now); tries.set(k, a); if (tries.size > 5000) tries.clear();
  return a.length > max;
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
  if (hit("e:" + email, 5) || hit("i:" + ip, 20)) return json({ ok: false, reason: "Too many tries. Wait 15 minutes and try again." }, 429);
  const now = Date.now(); fails = fails.filter((t) => now - t < 3600_000);
  if (fails.length >= 40) return json({ ok: false, reason: "Chausima sign-in is resting for a bit. Try again later, or use another way to sign in." }, 429);
  let good = false;
  try {
    const r = await fetch(MAIL, { headers: { Authorization: "Basic " + btoa(email + ":" + password), accept: "application/json" }, signal: AbortSignal.timeout(10_000) });
    good = r.ok; await r.body?.cancel();
    if (!r.ok && r.status !== 401 && r.status !== 403) return json({ ok: false, reason: "Chausima Mail isn't answering right now. Try again in a minute." }, 503);
  } catch { return json({ ok: false, reason: "Chausima Mail isn't answering right now. Try again in a minute." }, 503); }
  if (!good) { fails.push(now); return json({ ok: false, reason: "That Chausima address and password don't match." }); }
  tries.delete("e:" + email);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email, options: { data: { provider_hint: "chausima" } } });
  const token = data?.properties?.hashed_token;
  if (error || !token) {
    const m = String(error?.message ?? "").toLowerCase();
    return json({ ok: false, reason: m.includes("database") || m.includes("not allowed") ? "This Chausima account can't use the Launchpad yet. Ask the Launchpad owner to let it in." : "Couldn't sign you in just now. Try again." });
  }
  return json({ ok: true, token_hash: token, email });
});
