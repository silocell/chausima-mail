#!/usr/bin/env bash
# HWLAI reads from our own search engine (YaCy) first.
#   HWL_SEARCH=mix  (default) YaCy first; the open web (SearXNG, SafeSearch strict) only fills the gaps
#   HWL_SEARCH=ours           YaCy only - no open internet at all
# Edits the live hwchat function in place (backup kept), restarts functions, puts the old file back if anything fails.
set -e
F=/home/opc/supabase/volumes/functions/hwchat/index.ts; SB=/home/opc/supabase
[ -f "$F" ] || { echo "hwchat function not found at $F"; exit 1; }
if grep -q 'our own search engine (YaCy' "$F"; then echo "HWLAI already uses YaCy"; else
sudo cp "$F" "$F.bak-yacy-$(date +%Y%m%d%H%M)"
sudo python3 - "$F" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
a='''  try {
    const r = await fetch(`${SEARX}/search?`'''
b='''    if (r.ok) { const hits = keep((await r.json()).results ?? []); if (hits.length) return hits; }'''
c='''      if (r.ok) return keep((await r.json()).results ?? []);
    } catch { /* nothing */ }
  }
  return [];
}'''
for x in (a,b,c):
    if s.count(x)!=1: sys.exit("anchor not found once: "+x[:50])
s=s.replace(a,'''  // our own search engine (YaCy: safe learning sites we chose) comes first
  const YACY = Deno.env.get("YACY_URL") || "https://hehs-live.duckdns.org/search/v1";
  const MODE = (Deno.env.get("HWL_SEARCH") || "mix").toLowerCase();
  let ours: WebHit[] = [];
  try {
    const r = await fetch(`${YACY}?` + new URLSearchParams({ query: q, maximumRecords: "10" }), { headers: { accept: "application/json" }, signal: AbortSignal.timeout(SEARCH_MS) });
    if (r.ok) {
      const items = ((((await r.json()).channels ?? [])[0] ?? {}).items ?? []) as Array<Record<string, unknown>>;
      const tidy = (t: unknown) => String(t ?? "").replace(/<[^>]+>/g, "");
      ours = keep(items.map((i) => ({ title: tidy(i.title), url: String(i.link ?? ""), content: tidy(i.description) })));
    }
  } catch (e) { console.error("hw yacy", e instanceof Error ? e.name : String(e)); }
  if (MODE === "ours" || ours.length >= 4) return ours;
'''+a)
s=s.replace(b,'''    if (r.ok) { const hits = keep([...ours, ...((await r.json()).results ?? [])]); if (hits.length) return hits; }''')
s=s.replace(c,'''      if (r.ok) return keep([...ours, ...((await r.json()).results ?? [])]);
    } catch { /* nothing */ }
  }
  return ours;
}''')
open(p,'w').write(s); print("HWLAI now searches YaCy first")
PY
fi
SVC=$(sudo docker inspect supabase-edge-functions --format '{{index .Config.Labels "com.docker.compose.service"}}')
( cd $SB && sudo docker compose up -d --force-recreate --no-deps "$SVC" 2>&1 | tail -1 )
sleep 12
st=$(sudo docker inspect -f '{{.State.Status}}' supabase-edge-functions); echo "functions: $st"
code=$(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/functions/v1/hwchat)
echo "hwchat answers: $code"
if [ "$st" != running ] || [ "$code" = 000 ] || [ "$code" = 502 ] || [ "$code" = 503 ]; then
  B=$(ls -t "$F".bak-yacy-* | head -1); sudo cp "$B" "$F"; ( cd $SB && sudo docker compose up -d --force-recreate --no-deps "$SVC" >/dev/null 2>&1 ); echo "something went wrong - put the old HWLAI back"
fi
sudo docker logs --since 1m supabase-edge-functions 2>&1 | grep -iE "error|hwchat" | tail -3
