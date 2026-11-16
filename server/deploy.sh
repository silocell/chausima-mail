#!/bin/bash
# Puts the Chausima Mail web page live on the mail server. Run on the server:
#   curl -sL https://codeload.github.com/silocell/chausima-mail/tar.gz/main | tar xz && bash chausima-mail-main/server/deploy.sh
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd); CF=/etc/caddy/Caddyfile; D=/srv/chausima-mail
sudo mkdir -p $D
[ -f $D/index.html ] && sudo cp $D/index.html $D/index.html.before-deploy
sudo cp "$HERE"/web/{index.html,manifest.webmanifest,sw.js,icon-192.png,icon-512.png,logo.svg,icon.svg} $D/
sudo chmod a+r $D/*; sudo chcon -R -t httpd_sys_content_t $D 2>/dev/null || true
sudo cp $CF $CF.before-deploy
sudo python3 "$HERE/server/caddy_add_files.py" $CF
if sudo caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy; then echo "Caddy reloaded"
else sudo cp $CF.before-deploy $CF; sudo systemctl reload caddy; echo "Caddy: didn't validate - put back"; fi
for u in / /manifest.webmanifest /sw.js /icon-192.png /logo /admin/favicon.ico; do echo "$u -> $(curl -s -o /dev/null -w '%{http_code} %{content_type}' https://mail.chausima.com$u)"; done
echo "new page live: $(curl -s https://mail.chausima.com/ | grep -c 'Search in mail')"
