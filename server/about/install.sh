#!/usr/bin/env bash
# about.chausima.com: the story of how Chausima began (the old chausima.com front page).
# It lives in the HEH-Show repo at /about/ (GitHub Pages, chausima.com/about/); Caddy shows it at about.chausima.com,
# so pushing to GitHub updates it as usual. Needs DNS:  A  about  140.238.91.12.   Run:  bash install.sh
set -e
CF=/etc/caddy/Caddyfile
sudo cp $CF $CF.before-about
if ! sudo grep -q '^about.chausima.com' $CF; then
  sudo tee -a $CF >/dev/null <<'C'

about.chausima.com {
	rewrite * /about{uri}
	reverse_proxy https://chausima.com {
		header_up Host chausima.com
	}
}
C
fi
if sudo caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy; then echo "Caddy reloaded"
else sudo cp $CF.before-about $CF; sudo systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 8
echo "about.chausima.com -> $(curl -s -o /dev/null -w '%{http_code}' https://about.chausima.com/ || echo 'not yet (DNS or certificate still coming)')"
