/* Chausima ID: Chausima accounts (name@chausima.com, no mailbox) and "Sign in with Chausima" for Chausima tools.
   - Anyone can make an account: a username, a name and a password. Accounts give access to tools (the Chausima
     Suite and so on), never to email, and are kept apart from Launchpad accounts (the Launchpad stays school-only).
   - Passwords are stored only as PBKDF2-SHA256 hashes (210,000 rounds, random salt).
   - It's also a small OpenID Connect provider, so apps like CryptPad can offer "Sign in with Chausima".
     Issuer: https://hehs-live.duckdns.org/chausima-id  (Caddy passes /chausima-id/* to this function).
     Apps allowed to use it are listed in clients.json next to this file (written by the installer).
   Endpoints (POST JSON unless noted):
     /signup {username,name,password}     /login {username,password}     /me (Authorization: Chausima <token>)
     /password {old,new}                  /approve {req}  (after signing in on chausima.com/account)
     GET /.well-known/openid-configuration, GET /authorize, POST /token, GET|POST /userinfo, GET /jwks */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { usernameProblem, nameProblem } from "./names.ts";

const ISSUER = Deno.env.get("CHZ_ISSUER") || "https://hehs-live.duckdns.org/chausima-id";
const ACCOUNT_PAGE = "https://chausima.com/account/";
const DOMAIN = "chausima.com";
const SESSION_DAYS = 30;
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, s = 200, h: Record<string, string> = {}) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json", "cache-control": "no-store", ...h } });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const enc = new TextEncoder();

/* ---------- small helpers: base64url, HMAC JWTs, password hashes ---------- */
const b64u = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - s.length % 4) % 4)), (c) => c.charCodeAt(0));
async function hkey(secret: string) { return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]); }
const SIGN_SECRET = "chausima-id:" + (Deno.env.get("JWT_SECRET") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");
async function sign(claims: Record<string, unknown>, secret = SIGN_SECRET) {
  const h = b64u(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" }))), p = b64u(enc.encode(JSON.stringify(claims)));
  return h + "." + p + "." + b64u(await crypto.subtle.sign("HMAC", await hkey(secret), enc.encode(h + "." + p)));
}
async function verify(tok: string, use: string, secret = SIGN_SECRET): Promise<Record<string, any> | null> {
  try {
    const [h, p, s] = tok.split(".");
    if (!(await crypto.subtle.verify("HMAC", await hkey(secret), unb64u(s), enc.encode(h + "." + p)))) return null;
    const c = JSON.parse(new TextDecoder().decode(unb64u(p)));
    if (c.use !== use || (c.exp && c.exp < Date.now() / 1000)) return null;
    return c;
  } catch { return null; }
}
async function hashPw(pw: string, salt = crypto.getRandomValues(new Uint8Array(16)), rounds = 210000) {
  const k = await crypto.subtle.importKey("raw", enc.encode(pw), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: rounds }, k, 256);
  return `pbkdf2$${rounds}$${b64u(salt)}$${b64u(bits)}`;
}
async function checkPw(pw: string, stored: string) {
  const [kind, r, salt, want] = stored.split("$");
  if (kind !== "pbkdf2") return false;
  const got = (await hashPw(pw, unb64u(salt), +r)).split("$")[3];
  let d = got.length ^ want.length; for (let i = 0; i < Math.min(got.length, want.length); i++) d |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}
const now = () => Math.floor(Date.now() / 1000);
/* Caddy hands the caller's own Authorization over as X-Chz-Auth (the functions gateway needs its own key there) */
const authz = (req: Request) => req.headers.get("x-chz-auth") || req.headers.get("authorization") || "";
const usedCodes = new Map<string, number>();   // each sign-in code works once

/* ---------- limits (in memory) ---------- */
const hits = new Map<string, number[]>();
function over(k: string, max: number, ms: number) {
  const t = Date.now(), a = (hits.get(k) ?? []).filter((x) => t - x < ms); a.push(t); hits.set(k, a);
  if (hits.size > 10000) hits.clear();
  return a.length > max;
}

/* ---------- accounts ---------- */
type Acct = { id: string; username: string; name: string; pass: string; disabled: boolean };
const cleanUser = (u: unknown) => String(u ?? "").trim().toLowerCase().replace(/@chausima\.com$/, "");
const publicUser = (a: Acct) => ({ id: a.id, username: a.username, name: a.name, email: `${a.username}@${DOMAIN}` });
async function find(username: string): Promise<Acct | null> {
  const { data } = await db.from("chausima_accounts").select("id,username,name,pass,disabled").eq("username", username).maybeSingle();
  return data as Acct | null;
}
/* Someone with a real Chausima Mail mailbox (like the owner) can sign in with their mail password: the first time,
   Chausima Mail checks it and a Chausima account with the same name is made for them (even a kept username). */
async function fromMailbox(username: string, pw: string): Promise<Acct | null> {
  if (!/^[a-z0-9][a-z0-9._]{2,29}$/.test(username)) return null;
  try {
    const r = await fetch("https://mail.chausima.com/jmap/session", { headers: { Authorization: "Basic " + btoa(`${username}@${DOMAIN}:${pw}`), accept: "application/json" }, signal: AbortSignal.timeout(10000) });
    if (!r.ok) { await r.body?.cancel(); return null; }
    const j = await r.json().catch(() => ({}));
    const nm = Object.values((j as any).accounts ?? {}).map((x: any) => String(x?.name ?? "")).find((n) => n && !n.includes("@")) || username;
    const { data } = await db.from("chausima_accounts").insert({ username, name: nm.slice(0, 60), pass: await hashPw(pw) }).select("id,username,name,pass,disabled").single();
    return (data as Acct) ?? null;
  } catch { return null; }
}
async function session(a: Acct) { return sign({ use: "session", sub: a.id, u: a.username, iat: now(), exp: now() + SESSION_DAYS * 86400 }); }
async function fromSession(req: Request): Promise<Acct | null> {
  const t = authz(req).replace(/^(Chausima|Bearer)\s+/i, "");
  const c = await verify(t, "session"); if (!c) return null;
  const { data } = await db.from("chausima_accounts").select("id,username,name,pass,disabled").eq("id", c.sub).maybeSingle();
  return data && !(data as Acct).disabled ? data as Acct : null;
}

/* ---------- apps allowed to use "Sign in with Chausima" ---------- */
type Client = { secret: string; redirect: string[]; name?: string };
let clients: Record<string, Client> = {};
try { clients = JSON.parse(await Deno.readTextFile(new URL("./clients.json", import.meta.url))); } catch { /* none yet */ }

async function idToken(a: Acct, aud: string, nonce: string | undefined, secret: string) {
  return sign({ iss: ISSUER, sub: a.id, aud, iat: now(), exp: now() + 600, ...(nonce ? { nonce } : {}),
    name: a.name, preferred_username: a.username, email: `${a.username}@${DOMAIN}`, email_verified: true }, secret);
}
function clientAuth(req: Request, form: URLSearchParams): { id: string; c: Client } | null {
  let id = form.get("client_id") ?? "", secret = form.get("client_secret") ?? "";
  const basic = /^Basic\s+(.+)$/i.exec(authz(req));
  if (basic) { try { const [i, s] = atob(basic[1]).split(":"); id = decodeURIComponent(i); secret = decodeURIComponent(s ?? ""); } catch { /* bad */ } }
  const c = clients[id];
  return c && secret && c.secret === secret ? { id, c } : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/chausima-id/, "") || "/";
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const body = async () => { try { return await req.json(); } catch { return {}; } };

  /* ----- OpenID Connect ----- */
  if (path === "/.well-known/openid-configuration") return json({
    issuer: ISSUER, authorization_endpoint: ISSUER + "/authorize", token_endpoint: ISSUER + "/token", userinfo_endpoint: ISSUER + "/userinfo",
    jwks_uri: ISSUER + "/jwks", response_types_supported: ["code"], subject_types_supported: ["public"], grant_types_supported: ["authorization_code"],
    id_token_signing_alg_values_supported: ["HS256"], token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
    scopes_supported: ["openid", "profile", "email"], claims_supported: ["sub", "name", "preferred_username", "email", "email_verified"] });
  if (path === "/jwks") return json({ keys: [] });
  if (path === "/authorize") {
    const p = url.searchParams, cid = p.get("client_id") ?? "", ru = p.get("redirect_uri") ?? "", c = clients[cid];
    if (!c || !c.redirect.includes(ru)) return new Response("This app isn't allowed to use Sign in with Chausima.", { status: 400, headers: { "content-type": "text/plain; charset=utf-8" } });
    if (p.get("response_type") !== "code") return Response.redirect(ru + (ru.includes("?") ? "&" : "?") + "error=unsupported_response_type", 302);
    const cc = p.get("code_challenge") ?? "", ccm = p.get("code_challenge_method") ?? "";
    if (cc && ccm !== "S256") return Response.redirect(ru + (ru.includes("?") ? "&" : "?") + "error=invalid_request", 302);
    const r = await sign({ use: "authreq", cid, ru, st: p.get("state") ?? "", n: p.get("nonce") ?? "", cc, app: c.name ?? cid, exp: now() + 900 });
    return Response.redirect(ACCOUNT_PAGE + "?sso=" + encodeURIComponent(r), 302);
  }
  if (path === "/token" && req.method === "POST") {
    const form = new URLSearchParams(await req.text());
    const cl = clientAuth(req, form); if (!cl) return json({ error: "invalid_client" }, 401);
    if (form.get("grant_type") !== "authorization_code") return json({ error: "unsupported_grant_type" }, 400);
    const code = await verify(form.get("code") ?? "", "code");
    if (!code || code.cid !== cl.id || code.ru !== form.get("redirect_uri") || usedCodes.has(code.j)) return json({ error: "invalid_grant" }, 400);
    if (code.cc) {   // PKCE: the app must prove it's the one that started this sign-in
      const v = form.get("code_verifier") ?? "";
      if (!v || b64u(await crypto.subtle.digest("SHA-256", enc.encode(v))) !== code.cc) return json({ error: "invalid_grant" }, 400);
    }
    usedCodes.set(code.j, code.exp); for (const [k, e] of usedCodes) if (e < now()) usedCodes.delete(k);
    const { data } = await db.from("chausima_accounts").select("id,username,name,pass,disabled").eq("id", code.sub).maybeSingle();
    const a = data as Acct | null; if (!a || a.disabled) return json({ error: "invalid_grant" }, 400);
    const access = await sign({ use: "access", sub: a.id, cid: cl.id, exp: now() + 3600 });
    return json({ access_token: access, token_type: "Bearer", expires_in: 3600, id_token: await idToken(a, cl.id, code.n || undefined, cl.c.secret), scope: "openid profile email" });
  }
  if (path === "/userinfo") {
    const t = authz(req).replace(/^Bearer\s+/i, "");
    const c = await verify(t, "access"); if (!c) return json({ error: "invalid_token" }, 401);
    const { data } = await db.from("chausima_accounts").select("id,username,name,pass,disabled").eq("id", c.sub).maybeSingle();
    const a = data as Acct | null; if (!a || a.disabled) return json({ error: "invalid_token" }, 401);
    return json({ sub: a.id, name: a.name, preferred_username: a.username, email: `${a.username}@${DOMAIN}`, email_verified: true });
  }

  if (req.method !== "POST") return json({ error: "Nothing here." }, 404);

  /* ----- accounts ----- */
  if (path === "/signup") {
    if (over("s:" + ip, 5, 3600_000)) return json({ ok: false, reason: "Too many new accounts from here. Try again in an hour." }, 429);
    const b = await body(); const username = cleanUser(b.username), name = String(b.name ?? "").trim().replace(/\s+/g, " "), pw = String(b.password ?? "");
    if (!/^[a-z0-9][a-z0-9._]{2,29}$/.test(username) || /\.\.|\.$/.test(username)) return json({ ok: false, reason: "Usernames are 3–30 letters, numbers, dots or underscores, starting with a letter or number." });
    const up = usernameProblem(username); if (up) return json({ ok: false, reason: up });
    if (!name || name.length > 60) return json({ ok: false, reason: "Type your name (up to 60 letters)." });
    const np = nameProblem(name); if (np) return json({ ok: false, reason: np });
    if (pw.length < 8 || pw.length > 200) return json({ ok: false, reason: "Use a password of at least 8 characters." });
    if (pw.toLowerCase().includes(username)) return json({ ok: false, reason: "Don't put your username in your password." });
    const { data, error } = await db.from("chausima_accounts").insert({ username, name, pass: await hashPw(pw) }).select("id,username,name,pass,disabled").single();
    if (error) return json({ ok: false, reason: /duplicate|unique/i.test(error.message) ? "That username is taken. Try another." : "Couldn't make the account just now." });
    return json({ ok: true, token: await session(data as Acct), user: publicUser(data as Acct) });
  }
  if (path === "/login") {
    const b = await body(); const username = cleanUser(b.username), pw = String(b.password ?? "");
    if (over("l:" + username, 8, 900_000) || over("li:" + ip, 30, 900_000)) return json({ ok: false, reason: "Too many tries. Wait 15 minutes and try again." }, 429);
    let a = username ? await find(username) : null;
    if (!a && /^[a-z0-9][a-z0-9._-]{0,63}$/.test(username) && pw) a = await fromMailbox(username, pw);   // Chausima Mail people
    if (!a || a.disabled || !(await checkPw(pw, a.pass))) return json({ ok: false, reason: "That username and password don't match." });
    await db.from("chausima_accounts").update({ last_login: new Date().toISOString() }).eq("id", a.id);
    return json({ ok: true, token: await session(a), user: publicUser(a) });
  }
  const me = await fromSession(req);
  if (!me) return json({ ok: false, reason: "Sign in again." }, 401);
  if (path === "/me") return json({ ok: true, user: publicUser(me) });
  if (path === "/password") {
    const b = await body();
    if (over("p:" + me.id, 5, 900_000)) return json({ ok: false, reason: "Too many tries. Wait a bit." }, 429);
    if (!(await checkPw(String(b.old ?? ""), me.pass))) return json({ ok: false, reason: "Your current password isn't right." });
    const nw = String(b.new ?? ""); if (nw.length < 8 || nw.length > 200) return json({ ok: false, reason: "Use a new password of at least 8 characters." });
    await db.from("chausima_accounts").update({ pass: await hashPw(nw) }).eq("id", me.id);
    return json({ ok: true });
  }
  if (path === "/name") {
    const b = await body(); const name = String(b.name ?? "").trim().replace(/\s+/g, " ");
    if (!name || name.length > 60) return json({ ok: false, reason: "Type your name (up to 60 letters)." });
    const np = nameProblem(name); if (np) return json({ ok: false, reason: np });
    await db.from("chausima_accounts").update({ name }).eq("id", me.id);
    return json({ ok: true, user: publicUser({ ...me, name }) });
  }
  if (path === "/approve") {
    const b = await body(); const r = await verify(String(b.req ?? ""), "authreq");
    if (!r || !clients[r.cid] || !clients[r.cid].redirect.includes(r.ru)) return json({ ok: false, reason: "That sign-in link has expired. Go back to the app and try again." });
    const code = await sign({ use: "code", j: b64u(crypto.getRandomValues(new Uint8Array(12))), sub: me.id, cid: r.cid, ru: r.ru, n: r.n, cc: r.cc, exp: now() + 120 });
    const q = new URLSearchParams({ code, ...(r.st ? { state: r.st } : {}) });
    return json({ ok: true, app: r.app, redirect: r.ru + (r.ru.includes("?") ? "&" : "?") + q.toString() });
  }
  return json({ error: "Nothing here." }, 404);
});
