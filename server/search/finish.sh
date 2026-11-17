#!/usr/bin/env bash
# Chausima Search: start the Wikipedia import (needs a POST) and switch on the public search route.
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
echo "wikipedia import: $(curl -s -o /dev/null -w '%{http_code}' --digest -u "admin:$PW" --data-urlencode 'file=/opt/yacy_search_server/DATA/dumps/simplewiki-latest-pages-articles.xml.bz2' http://127.0.0.1:8090/IndexImportMediawiki_p.html)"
curl -sL https://raw.githubusercontent.com/silocell/chausima-mail/353b0bc/server/search/search-route.sh | bash
sleep 20
curl -s --digest -u "admin:$PW" http://127.0.0.1:8090/api/status_p.json | tr ',{}' '\n\n\n' | grep -E '"(loaderqueue|localcrawlerqueue|indexingqueue|ppm|urlpublictext)"' | tr '\n' ' '; echo
