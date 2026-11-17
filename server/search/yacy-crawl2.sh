#!/usr/bin/env bash
# Chausima Search, round 2: same as yacy-crawl.sh but signs in as admin (round 1 was refused with 401),
# goes 5x faster (300 pages a minute in total, still one polite request at a time per site, robots.txt obeyed),
# and covers more kid-safe learning sites.
set -uo pipefail
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
Y(){ curl -s --digest -u "admin:$PW" -G "http://127.0.0.1:8090/$1" "${@:2}"; }
code(){ curl -s -o /dev/null -w '%{http_code}' --digest -u "admin:$PW" -G "http://127.0.0.1:8090/$1" "${@:2}"; }
echo "admin check: $(code api/status_p.json)"
DUMP=simplewiki-latest-pages-articles.xml.bz2
echo "wikipedia import: $(code IndexImportMediawiki_p.html --data-urlencode "file=/opt/yacy_search_server/DATA/dumps/$DUMP")"
echo "speed: $(code Crawler_p.html -d crawlingPerformance=custom -d customPPM=300)"
crawl(){  # url range maxpages
  c=$(code Crawler_p.html -d crawlingstart=1 -d crawlingMode=url --data-urlencode "crawlingURL=$1" -d "range=$2" \
    -d crawlingDepth=6 -d crawlingDomMaxCheck=on -d "crawlingDomMaxPages=$3" -d crawlingQ=off \
    -d indexText=on -d indexMedia=off -d storeHTCache=off -d obeyHtmlRobotsNoindex=on -d obeyHtmlRobotsNofollow=on \
    -d cachePolicy=iffresh -d deleteold=off \
    --data-urlencode 'mustnotmatch=.*(login|signin|sign-in|register|account|basket|cart|checkout|/search|\?).*')
  echo "$c  $1"
}
crawl https://www.bbc.co.uk/bitesize/            subpath 20000
crawl https://www.bbc.co.uk/newsround/           subpath 4000
crawl https://www.mathsisfun.com/                domain 6000
crawl https://corbettmaths.com/                  domain 3000
crawl https://www.mathsgenie.co.uk/              domain 2000
crawl https://www.mrbartonmaths.com/             domain 1500
crawl https://revisionworld.com/                 domain 5000
crawl https://www.s-cool.co.uk/                  domain 3000
crawl https://www.chemguide.co.uk/               domain 3000
crawl https://www.physicsclassroom.com/          domain 5000
crawl https://www.savemyexams.com/               domain 5000
crawl https://www.physicsandmathstutor.com/      domain 3000
crawl https://www.internetgeography.net/         domain 3000
crawl https://www.natgeokids.com/uk/             subpath 3000
crawl https://www.historyextra.com/              domain 5000
crawl https://www.tutor2u.net/                   domain 3000
crawl https://www.ducksters.com/                 domain 5000
crawl https://kids.kiddle.co/                    domain 20000
crawl https://www.sciencekids.co.nz/             domain 3000
crawl https://www.nhm.ac.uk/discover/            subpath 3000
crawl https://www.rmg.co.uk/stories/             subpath 3000
crawl https://www.metoffice.gov.uk/weather/learn-about/ subpath 2000
crawl https://www.nasa.gov/learning-resources/   subpath 4000
crawl https://www.historic-uk.com/               domain 4000
crawl https://www.coolgeography.co.uk/           domain 2000
crawl https://www.bbc.co.uk/teach/               subpath 4000
sleep 60
echo "== after a minute"
Y api/status_p.json | tr ',{}' '\n\n\n' | grep -E '"(loaderqueue|localcrawlerqueue|indexingqueue|ppm|urlpublictext|rwipublictext)"' | tr '\n' ' '; echo
sudo du -sh /mnt/launchpad-data/yacy/INDEX
