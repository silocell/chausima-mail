#!/usr/bin/env bash
# Chausima Suite branding on top of CryptPad: logo, favicon, name and wording. Files go in CryptPad's own
# "customize" folder (/mnt/launchpad-data/cryptpad/customize), which CryptPad checks before its defaults and
# never overwrites, so they survive restarts and updates. The source-code credit to CryptPad stays (AGPL).
# Safe to re-run. Run:  sudo bash rebrand.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd); C=/mnt/launchpad-data/cryptpad/customize
mkdir -p $C/translations
cp $HERE/brand/*.svg $HERE/brand/main-favicon.png $HERE/brand/favicon.ico $HERE/brand/application_config.js $C/
cp $HERE/brand/translations/messages.js $C/translations/
# the front page title: CryptPad shows the web address until an admin names the instance; show "Chausima Suite" instead
docker exec cryptpad cat /cryptpad/customize.dist/pages.js > $C/pages.js.new
python3 - $C/pages.js.new <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
swaps = [
  ("new URL('/', ApiConfig.httpUnsafeOrigin).host", "'Chausima Suite'"),           # front page name
  ("name = 'CryptPad';", "name = 'Chausima Suite';"),
  ("if (!ApiConfig.removeDonateButton) {", "if (false) {"),                          # no donate button
  ("h('a', {href:\"https://cryptpad.org\", role: 'button'}", "h('a', {href:\"https://chausima.com\", role: 'button'}"),
  ("h('span.logo-font', 'CryptPad')", "h('span.logo-font', 'Chausima Suite')"),
  ("footLink('https://cryptpad.org', null, Msg.footer_website, 'link')",             # keep the source credit (AGPL)
   "footLink('https://github.com/cryptpad/cryptpad', null, 'Built on CryptPad (source code)', 'link'), footLink('https://suite.civilinitiatives.org/?classic=1', null, 'Classic Launchpad Suite', 'link')"),
  ("'https://docs.cryptpad.org'", "'https://about.chausima.com'"),
]
for a, b in swaps:
    if a in s: s = s.replace(a, b)
    else: print("  (not found in this version, left as is: %s)" % a[:50])
open(p, 'w').write(s)
PY
mv $C/pages.js.new $C/pages.js
chown -R 4001:4001 $C
docker restart cryptpad >/dev/null && echo "Suite restarting with the Chausima look (about a minute)"
for i in $(seq 1 40); do c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/ || true); [ "$c" = 200 ] && break; sleep 5; done
echo "suite -> $c"
curl -s http://127.0.0.1:3100/customize/translations/messages.js | grep -q "Chausima Suite" && echo "wording: Chausima" || echo "wording: not served - tell Claude"
