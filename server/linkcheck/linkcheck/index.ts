/* linkcheck: is a web page OK to show a pupil in HWL OS's Browser?
   The server reads the page (never private or internal addresses), then the same school-safety
   check as the Launchpad AI (gpt-oss-safeguard on Groq, then Llama Guard on Cloudflare) decides.
   Signed-in Launchpad users, and the HWL Browser apps (120 fresh checks an hour per connection). Answers are remembered for 6 hours. If nothing can check a page,
   it stays blocked, except trusted learning sites. YouTube videos are checked by their title. */
import { createClient } from "jsr:@supabase/supabase-js@2";
const CF_ACCOUNT = "fc6f56f0a20877232943b4d37db90086";
const GUARD_MS = 8000, PAGE_MS = 7000, PAGE_BYTES = 400_000;
const TRUSTED = /(^|\.)(wikipedia\.org|wikimedia\.org|bbc\.co\.uk|civilinitiatives\.org|chausima\.com|kiddle\.co|nasa\.gov|nhm\.ac\.uk|britannica\.com|natgeokids\.com|mathsisfun\.com|gov\.uk|scratch\.mit\.edu|khanacademy\.org|developer\.mozilla\.org|w3schools\.com)$/i;
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

const BLOCK: Record<string, string> = { S1: "violence", S2: "crime", S3: "sexual violence", S4: "content involving children", S9: "weapons", S10: "hate", S11: "self-harm", S12: "sexual content" };
function verdict(raw: string): { ok: boolean; hits: string[] } | undefined {
  const v = String(raw ?? "").trim(); if (!v) return undefined;
  if (/^safe\b/i.test(v)) return { ok: true, hits: [] };
  const codes = v.toUpperCase().match(/S\d+/g) ?? []; if (!codes.length) return undefined;
  const hits = codes.filter((c) => c in BLOCK).map((c) => BLOCK[c]);
  return { ok: !hits.length, hits };
}
export const SAFEGUARD = "openai/gpt-oss-safeguard-20b";
export const POLICY = `# School safety policy
You check messages that students (mostly aged 11-18) send to an AI helper.

## Instructions
Decide whether the MESSAGE breaks this policy. Answer with JSON only, no other text:
{"violation": 0 or 1, "category": "<one code below, or none>"}

## Violations (use the code)
- S1 violence: asks for help to attack, threaten or hurt a real person or animal, or praises a real attack.
- S2 crime: asks for real steps to steal, hack someone, make or buy drugs, or commit fraud.
- S3 sexual violence: describes or asks for sexual violence.
- S4 children: any sexual content involving under-18s, or an adult trying to get a child alone or to keep secrets.
- S9 weapons: how to make or get weapons, explosives or poisons.
- S10 hate: insults or attacks people for race, religion, sex, sexuality, disability or similar.
- S11 self-harm: the writer may hurt or kill themselves, or asks how to, or about extreme dieting.
- S12 sexual: sexual or pornographic content.

## Not violations
- Learning about hard topics: wars, the Holocaust, slavery, crime in history or the news, how diseases or drugs affect the body, sex education at school level, poems or books with dark themes.
- Fiction and essays that mention violence without giving real instructions.
- Rude words, jokes, games, coding, maths, small talk.
When unsure whether something is learning or a real plan, it is learning (0), except for S4 and S11, where unsure means 1.`;

export function sgVerdict(raw: string): { ok: boolean; hits: string[] } | undefined {
  const s = String(raw ?? "");
  const m = s.match(/\{[\s\S]*?\}/); if (!m) return undefined;
  try {
    const j = JSON.parse(m[0]);
    const v = Number(j.violation);
    if (v === 0) return { ok: true, hits: [] };
    if (v !== 1) return undefined;
    const code = String(j.category ?? "").toUpperCase().match(/S\d+/)?.[0];
    // a violation with a code we don't block (or no code) still counts - better safe
    return { ok: false, hits: [code && code in BLOCK ? BLOCK[code] : "not allowed here"] };
  } catch { return undefined; }
}
const NOT_FOR_SCHOOL = /(^|\.)(pornhub|xvideos|xnxx|xhamster|onlyfans|redtube|youporn|chaturbate|stripchat|4chan|8kun|kiwifarms|bet365|williamhill|paddypower|skybet|betfair|stake|roobet|888casino)\.|\.(xxx|porn|sex|adult|casino|bet)$/i;
export type WebHit = { title: string; url: string; content: string };
export type Source = { n: number; title: string; url: string; site: string };
/* only ordinary public web pages: no IP addresses, local names, odd ports, passwords in links, or our own servers */
export function safeUrl(u: string): URL | null {
  let x: URL; try { x = new URL(u); } catch { return null; }
  if ((x.protocol !== "https:" && x.protocol !== "http:") || x.username || x.password) return null;
  if (x.port && x.port !== "80" && x.port !== "443") return null;
  const h = x.hostname.toLowerCase();
  if (!h.includes(".") || /^[\d.]+$/.test(h) || h.includes(":") || h.startsWith("[")) return null;
  if (/(^|\.)(localhost|local|internal|lan|home|corp|intranet|arpa|test|invalid)$/i.test(h) || /(^|\.)duckdns\.org$|(^|\.)oraclecloud\.com$|metadata/i.test(h)) return null;
  if (NOT_FOR_SCHOOL.test(h)) return null;
  return x;
}
const PRIVATE_IP = /^(0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|22[4-9]\.|2[3-5]\d\.)|^(::1?$|f[cd]|fe[89ab]|::ffff:)/i;
async function publicHost(h: string): Promise<boolean> {
  if (typeof Deno.resolveDns !== "function") return true;   // can't look it up here: the name rules above still apply
  const a = await Deno.resolveDns(h, "A").catch(() => [] as string[]), b = await Deno.resolveDns(h, "AAAA").catch(() => [] as string[]);
  const ips = [...a, ...b];
  return ips.length > 0 && !ips.some((ip) => PRIVATE_IP.test(ip));
}
const ENT: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", ndash: "–", mdash: "—", hellip: "…", rsquo: "’", lsquo: "‘", ldquo: "“", rdquo: "”", pound: "£", copy: "©" };
const unent = (t: string) => t.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (m, e: string) => e[0] === "#" ? (() => { const c = e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10); return c > 0 && c < 0x110000 ? String.fromCodePoint(c) : " "; })() : ENT[e.toLowerCase()] ?? m);
export function pageText(html: string): { title: string; text: string } {
  const title = unent((html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "").replace(/\s+/g, " ").trim()).slice(0, 160);
  let t = html.replace(/<head\b[\s\S]*?<\/head>/i, " ").replace(/<(title|script|style|noscript|svg|nav|footer|header|form|iframe|template|aside|select|button)\b[\s\S]*?<\/\1>/gi, " ").replace(/<!--[\s\S]*?-->/g, " ");
  t = t.replace(/<(br|p|div|li|h[1-6]|tr|section|article|blockquote|dd|dt)\b[^>]*>/gi, "\n").replace(/<[^>]+>/g, " ");
  t = unent(t).replace(/[ \t\f\v\r ]+/g, " ").replace(/ *\n[\s]*/g, "\n").trim();
  return { title, text: t };
}

async function guard(text: string, extra = ""): Promise<{ ok: boolean; hits: string[] } | undefined> {
  const keys = ["GROQ_API_KEY", "GROQ_API_KEY_2"].map((k) => Deno.env.get(k)).filter(Boolean) as string[];
  for (const key of keys) {
    try {
      const r = await fetch("https://api.groq.com/openai/v1/chat/completions", { method: "POST", headers: { "content-type": "application/json", Authorization: `Bearer ${key}` },
        body: JSON.stringify({ model: SAFEGUARD, reasoning_effort: "low", temperature: 0, max_tokens: 400,
          messages: [{ role: "system", content: POLICY + extra }, { role: "user", content: "WEB PAGE A PUPIL WANTS TO OPEN:\n" + text.slice(0, 6000) }] }),
        signal: AbortSignal.timeout(GUARD_MS) });
      if (r.ok) { const v = sgVerdict((await r.json()).choices?.[0]?.message?.content ?? ""); if (v) return v; }
      else if (r.status !== 429) break;
    } catch { /* next */ }
  }
  const cf = Deno.env.get("CF_API_TOKEN");
  if (cf) {
    try {
      const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/ai/run/@cf/meta/llama-guard-3-8b`, { method: "POST",
        headers: { "content-type": "application/json", Authorization: `Bearer ${cf}` }, body: JSON.stringify({ messages: [{ role: "user", content: text.slice(0, 6000) }], max_tokens: 64 }), signal: AbortSignal.timeout(GUARD_MS) });
      if (r.ok) { const v = verdict((await r.json()).result?.response ?? ""); if (v) return v; }
    } catch { /* nothing answered */ }
  }
  return undefined;
}

async function read(u: URL): Promise<{ title: string; text: string; desc: string } | null> {
  let url: URL | null = u;
  for (let hop = 0; url && hop < 4; hop++) {
    try {
      if (!await publicHost(url.hostname)) return null;
      const r = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(PAGE_MS), headers: { "user-agent": "Mozilla/5.0 (compatible; HWLOS-LinkCheck/1.0; +https://civilinitiatives.org)", accept: "text/html,text/plain;q=0.9", "accept-language": "en-GB,en;q=0.8" } });
      if (r.status >= 300 && r.status < 400) { const loc = r.headers.get("location"); await r.body?.cancel(); url = loc ? safeUrl(new URL(loc, url).toString()) : null; continue; }
      if (!r.ok || !r.body || !/text\/(html|plain)|application\/xhtml/i.test(r.headers.get("content-type") ?? "")) { await r.body?.cancel(); return { title: "", text: "", desc: "" }; }
      const rd = r.body.getReader(); const parts: Uint8Array[] = []; let got = 0;
      while (got < PAGE_BYTES) { const { value, done } = await rd.read(); if (done) break; parts.push(value); got += value.length; }
      await rd.cancel().catch(() => {});
      const all = new Uint8Array(got); let at = 0; for (const p of parts) { all.set(p, at); at += p.length; }
      const html = new TextDecoder().decode(all);
      const desc = unent((html.match(/<meta[^>]+name=["']description["'][^>]+content=["']([^"']*)/i)?.[1] ?? "")).slice(0, 300);
      const p = pageText(html);
      return { title: p.title, text: p.text.slice(0, 5000), desc };
    } catch { return { title: "", text: "", desc: "" }; }
  }
  return null;
}

const cache = new Map<string, { at: number; res: Record<string, unknown> }>();
const rate = new Map<string, { at: number; n: number }>();
const SIX_H = 6 * 3600_000;
/* The HWL Browser apps ask for YouTube videos to be judged like a UK "15" rating. */
const AGE15 = `

## YouTube videos (this request)
The viewer is about 15. Judge the video like a UK "15" film rating: strong language, crude humour, scary or horror themes, fighting in games and films, and moderate violence are all fine (0).
Still a violation: sexual or pornographic content, nudity, graphic gore, real instructions for harm, hate, or self-harm content.
A video being marked 18+ by its creator is not by itself a violation: judge what it actually is.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const auth = req.headers.get("authorization") ?? "";
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: who } = await db.auth.getUser().catch(() => ({ data: { user: null } }));
  const app = (req.headers.get("x-hwl-app") ?? "").startsWith("hwl-browser");
  if (!who?.user && !app) return json({ ok: false, reason: "Sign in on the Homework Launchpad to open web pages." }, 401);
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  let body: { url?: string; age?: number } = {}; try { body = await req.json(); } catch { /* empty */ }
  const u = safeUrl(String(body.url ?? ""));
  if (!u) return json({ ok: false, reason: "That address can't be opened here." });
  const host = u.hostname.toLowerCase();
  if (TRUSTED.test(host)) return json({ ok: true, trusted: true });
  const age15 = body.age === 15;
  const key = u.toString() + (age15 ? "#15" : ""), hostKey = "host:" + host, now = Date.now();
  const hc = cache.get(hostKey); if (hc && now - hc.at < SIX_H) return json({ ...hc.res, cached: true });
  const pc = cache.get(key); if (pc && now - pc.at < SIX_H) return json({ ...pc.res, cached: true });
  let sample = "", extra = "";
  if (/(^|\.)(youtube\.com|youtube-nocookie\.com|youtu\.be)$/i.test(host)) {
    const id = u.toString().match(/(?:embed\/|shorts\/|live\/|v=|youtu\.be\/)([\w-]{6,})/)?.[1];
    if (!id) return json({ ok: false, reason: "Only single YouTube videos can be opened here." });
    try {
      const r = await fetch("https://www.youtube.com/oembed?format=json&url=" + encodeURIComponent("https://www.youtube.com/watch?v=" + id), { signal: AbortSignal.timeout(PAGE_MS) });
      if (!r.ok) return json({ ok: false, reason: "That video isn't available." });
      const o = await r.json(); sample = `YouTube video\nTitle: ${o.title}\nChannel: ${o.author_name}`; if (age15) extra = AGE15;
    } catch { return json({ ok: false, reason: "Couldn't look up that video just now." }); }
  } else {
    const page = await read(u);
    if (page === null) return json({ ok: false, reason: "That address can't be opened here." });
    sample = `Address: ${u.toString()}\nTitle: ${page.title}\nDescription: ${page.desc}\n\n${page.text}`;
  }
  if (!who?.user) {   // the HWL Browser apps: at most 120 fresh checks an hour per connection
    const now2 = Date.now(), r = rate.get(ip);
    if (!r || now2 - r.at > 3600_000) rate.set(ip, { at: now2, n: 1 });
    else if (++r.n > 120) return json({ ok: false, reason: "That's a lot of new websites in a short time. Try again in a few minutes." });
  }
  const v = await guard(sample, extra);
  let res: Record<string, unknown>;
  if (!v) res = { ok: false, reason: "The safety check isn't answering right now, so this page stays closed. Try again in a minute." };
  else if (v.ok) res = { ok: true };
  else res = { ok: false, reason: `This page isn't suitable for school (${v.hits.join(", ")}).` };
  if (v) { cache.set(key, { at: now, res }); if (!v.ok && !extra && !sample.startsWith("YouTube video")) cache.set(hostKey, { at: now, res }); }
  if (cache.size > 5000) cache.clear();
  return json(res);
});
