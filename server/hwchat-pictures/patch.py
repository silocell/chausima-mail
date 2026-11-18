#!/usr/bin/env python3
"""Pictures for the Launchpad AI (ai.civilinitiatives.org): patches the live hwchat function.
A picture the pupil pastes or attaches is looked at by a vision AI (Llama 4 Scout on Groq), which
  1. says whether it's OK for school (sexual content, nudity, gore, self-harm -> blocked like any message), and
  2. writes out everything in it: all the text exactly, diagrams, graphs, tables.
That description then goes through the normal safety check and personal-info filter, and on to whichever AI was
picked, so every AI can use the picture. The picture itself is never saved; only the description is.
If the vision AI can't answer, the words read on the pupil's device are used instead (as before).
Usage: python3 patch.py /path/to/hwchat/index.ts   (makes index.ts.before-pictures first)"""
import sys, shutil
p = sys.argv[1]; s = open(p).read()
if "seePicture(" in s:
    print("already patched"); sys.exit(0)

FN = r'''/* ---- pictures: a vision AI checks and describes each one (the picture itself is never saved) ---- */
const VISION = ["meta-llama/llama-4-scout-17b-16e-instruct", "meta-llama/llama-4-maverick-17b-128e-instruct"];
const SEE_PROMPT = `A school pupil (aged 11-16) attached this picture to a question for their homework helper AI.
Line 1: write SAFE, or UNSAFE: <a few words why>. UNSAFE is only for sexual content or nudity, graphic gore or injury, self-harm, or extreme violence. Ordinary school work, screenshots, games, memes, photos of people or places are SAFE.
Then, for another AI that cannot see the picture, describe it completely:
- copy ALL the writing exactly (questions, numbers, labels, handwriting, equations), keeping its layout;
- describe any diagram, graph, map or drawing precisely (axes, values, shapes, measurements, angles, arrows);
- write any table as a Markdown table;
- say briefly what kind of picture it is (a worksheet, a screenshot of a website, a photo of a textbook...).
Do not answer the question in it and do not add opinions.`;
export async function seePicture(type: string, data: string): Promise<{ safe: boolean; why: string; text: string } | null> {
  const keys = ["GROQ_API_KEY", "GROQ_API_KEY_2"].map((k) => Deno.env.get(k)).filter(Boolean) as string[];
  for (const key of keys) for (const model of VISION) {
    try {
      const r = await fetch("https://api.groq.com/openai/v1/chat/completions", { method: "POST",
        headers: { "content-type": "application/json", Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(30000),
        body: JSON.stringify({ model, temperature: 0, max_tokens: 1500, messages: [{ role: "user", content: [
          { type: "text", text: SEE_PROMPT }, { type: "image_url", image_url: { url: `data:${type};base64,${data}` } }] }] }) });
      if (!r.ok) { await r.body?.cancel(); continue; }   // busy, or that model is gone: try the next
      const out = String((await r.json()).choices?.[0]?.message?.content ?? "").trim();
      if (!out) return null;
      const first = out.split("\n")[0].trim(), rest = out.split("\n").slice(1).join("\n").trim();
      const bad = /^\W*UNSAFE/i.test(first);
      if (!bad && !/^\W*SAFE/i.test(first)) return { safe: true, why: "", text: out.slice(0, 5000) };
      return { safe: !bad, why: bad ? first.replace(/^\W*UNSAFE\W*/i, "").slice(0, 80) : "", text: rest.slice(0, 5000) };
    } catch { /* next */ }
  }
  return null;
}

'''
BLOCK = r'''  // pictures: looked at by the vision AI; its description replaces the back-up words read on the device
  const picHits: string[] = [];
  const imagesIn = (Array.isArray(body.images) ? body.images : []).slice(0, 3) as Array<{ name?: unknown; type?: unknown; data?: unknown }>;
  const seen = await Promise.all(imagesIn.map(async (im) => {
    const type = /^image\/(jpeg|png|webp)$/.test(String(im?.type)) ? String(im.type) : "";
    const data = String(im?.data ?? "");
    if (!type || data.length > 5_500_000 || !/^[A-Za-z0-9+/=]+$/.test(data)) return null;
    return { name: String(im?.name ?? "").replace(/[\\/<>\n\r"]/g, "_").slice(0, 80), see: await seePicture(type, data) };
  }));
  for (const s of seen) {
    if (!s || !s.see) continue;
    if (!s.see.safe) { picHits.push("picture: " + (s.see.why || "not suitable")); continue; }
    const f = files0.find((x) => x.name === s.name) ?? (files0.length < 5 ? (files0.push({ name: s.name || "Picture", text: "" }), files0[files0.length - 1]) : null);
    if (f) f.text = "A picture the pupil attached, described by an AI that looked at it:\n" + s.see.text;
  }

'''
A = '''  // take out personal information first: it isn't sent anywhere or saved\n'''
B = '''  const hits = [...new Set(checks.flatMap((c) => c!.hits))];'''
C = '''export async function claude(model: string'''
miss = [n for n, a in (("A", A), ("B", B), ("C", C)) if s.count(a) != 1]
if miss:
    print("can't patch: this hwchat is different from expected (missing %s) - nothing changed" % ",".join(miss)); sys.exit(2)
shutil.copy(p, p + ".before-pictures")
s = s.replace(C, FN + C, 1)
s = s.replace(A, BLOCK + A, 1)
s = s.replace(B, '''  const hits = [...new Set([...checks.flatMap((c) => c!.hits), ...picHits])];''', 1)
open(p, "w").write(s)
print("patched (backup: index.ts.before-pictures)")
