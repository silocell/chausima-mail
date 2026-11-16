#!/usr/bin/env bash
# Chausima Search: fills the private YaCy index.
#  1. Simple English Wikipedia, from Wikimedia's official download (no crawling of Wikipedia)
#  2. Homework sites, crawled politely: obeys robots.txt and noindex, 60 pages a minute in total,
#     page cap per site, no login/search/basket pages, no images/videos.
# YouTube is NOT crawled (its rules forbid it): videos come from the CTube feed instead.
set -euo pipefail
Y(){ sudo docker exec yacy curl -s -G "http://127.0.0.1:8090/$1" "${@:2}"; }   # local admin call
D=/mnt/launchpad-data/yacy/dumps; DUMP=simplewiki-latest-pages-articles.xml.bz2
sudo mkdir -p "$D"
if [ ! -s "$D/$DUMP" ]; then
  echo "downloading Simple English Wikipedia..."
  sudo curl -sfL -A "ChausimaSearch/1.0 (shiv@chausima.com)" -o "$D/$DUMP" "https://dumps.wikimedia.org/simplewiki/latest/$DUMP"
fi
sudo chown -R 107:"$(stat -c %g /mnt/launchpad-data/yacy)" "$D"
ls -lh "$D/$DUMP" | awk '{print "dump", $5}'
Y IndexImportMediawiki_p.html --data-urlencode "file=/opt/yacy_search_server/DATA/dumps/$DUMP" -o /dev/null && echo "wikipedia import started"

# overall crawl speed: 60 pages a minute
Y Crawler_p.html -d crawlingPerformance=custom -d customPPM=60 -o /dev/null
crawl(){  # url range maxpages
  Y Crawler_p.html -d crawlingstart=1 -d crawlingMode=url --data-urlencode "crawlingURL=$1" -d "range=$2" \
    -d crawlingDepth=5 -d crawlingDomMaxCheck=on -d "crawlingDomMaxPages=$3" -d crawlingQ=off \
    -d indexText=on -d indexMedia=off -d storeHTCache=off -d obeyHtmlRobotsNoindex=on -d obeyHtmlRobotsNofollow=on \
    -d cachePolicy=iffresh -d deleteold=off \
    --data-urlencode 'mustnotmatch=.*(login|signin|sign-in|register|account|basket|cart|checkout|/search|\?).*' -o /dev/null \
    && echo "crawl queued: $1"
}
crawl https://www.bbc.co.uk/bitesize/            subpath 8000
crawl https://www.bbc.co.uk/newsround/           subpath 2000
crawl https://www.mathsisfun.com/                domain 4000
crawl https://corbettmaths.com/                  domain 2000
crawl https://www.mathsgenie.co.uk/              domain 1500
crawl https://www.mrbartonmaths.com/             domain 1000
crawl https://revisionworld.com/                 domain 3000
crawl https://www.s-cool.co.uk/                  domain 2000
crawl https://www.chemguide.co.uk/               domain 2000
crawl https://www.physicsclassroom.com/          domain 3000
crawl https://www.savemyexams.com/               domain 3000
crawl https://www.physicsandmathstutor.com/      domain 2000
crawl https://www.internetgeography.net/         domain 2000
crawl https://www.natgeokids.com/uk/             subpath 2000
crawl https://www.historyextra.com/              domain 3000
crawl https://www.tutor2u.net/                   domain 2000
crawl https://www.ducksters.com/                 domain 3000
sleep 20
Y api/status_p.json | tr ',' '\n' | grep -E '"(loaderqueue|localcrawlerqueue|urlpublictext|rwipublictext|memoryUsed|memoryMax)"' || true
