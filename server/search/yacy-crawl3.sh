#!/usr/bin/env bash
# Chausima Search, round 3: a big, days-long crawl of SAFE learning sites only (no whole-web crawl:
# this index feeds a school search). 600 pages a minute in total, robots.txt obeyed, polite per site.
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
code(){ curl -s -o /dev/null -w '%{http_code}' --digest -u "admin:$PW" -G "http://127.0.0.1:8090/$1" "${@:2}"; }
echo "speed: $(code Crawler_p.html -d crawlingPerformance=custom -d customPPM=600)"
crawl(){ echo "$(code Crawler_p.html -d crawlingstart=1 -d crawlingMode=url --data-urlencode "crawlingURL=$1" -d "range=$2" \
  -d crawlingDepth=8 -d crawlingDomMaxCheck=on -d "crawlingDomMaxPages=$3" -d crawlingQ=off -d indexText=on -d indexMedia=off \
  -d storeHTCache=off -d obeyHtmlRobotsNoindex=on -d obeyHtmlRobotsNofollow=on -d cachePolicy=iffresh -d deleteold=off \
  --data-urlencode 'mustnotmatch=.*(login|signin|sign-in|register|account|basket|cart|checkout|/search|\?).*')  $1"; }
for s in \
 "https://kids.kiddle.co/ domain 50000" "https://www.bbc.co.uk/bitesize/ subpath 50000" "https://www.britannica.com/ domain 30000" \
 "https://www.mathsisfun.com/ domain 20000" "https://www.ducksters.com/ domain 20000" "https://www.historyextra.com/ domain 20000" \
 "https://www.nationalgeographic.com/ domain 20000" "https://kids.nationalgeographic.com/ domain 10000" "https://www.natgeokids.com/uk/ subpath 10000" \
 "https://www.nasa.gov/ domain 30000" "https://spaceplace.nasa.gov/ domain 5000" "https://www.esa.int/kids/ subpath 5000" \
 "https://www.nhm.ac.uk/ domain 15000" "https://www.sciencemuseum.org.uk/ domain 10000" "https://www.rmg.co.uk/ domain 10000" \
 "https://www.britishmuseum.org/ domain 10000" "https://www.metoffice.gov.uk/weather/learn-about/ subpath 5000" \
 "https://www.gov.uk/ domain 30000" "https://www.parliament.uk/education/ subpath 5000" "https://www.nhs.uk/ domain 20000" \
 "https://www.khanacademy.org/ domain 20000" "https://www.physicsclassroom.com/ domain 10000" "https://www.chemguide.co.uk/ domain 5000" \
 "https://www.savemyexams.com/ domain 20000" "https://www.physicsandmathstutor.com/ domain 10000" "https://revisionworld.com/ domain 10000" \
 "https://www.internetgeography.net/ domain 10000" "https://www.coolgeography.co.uk/ domain 5000" "https://www.historic-uk.com/ domain 10000" \
 "https://www.sciencekids.co.nz/ domain 10000" "https://www.dogonews.com/ domain 10000" "https://www.wwf.org.uk/ domain 5000" \
 "https://www.rspb.org.uk/ domain 10000" "https://www.ox.ac.uk/ domain 10000" "https://www.cam.ac.uk/ domain 10000" \
 "https://www.gutenberg.org/ domain 30000" "https://www.bbc.co.uk/newsround/ subpath 20000" "https://www.bbc.co.uk/teach/ subpath 20000" \
 "https://scratch.mit.edu/ideas subpath 2000" "https://en.scratch-wiki.info/ domain 20000" "https://www.codecademy.com/resources/docs/ subpath 10000" \
 "https://developer.mozilla.org/en-US/docs/ subpath 40000" "https://www.w3schools.com/ domain 20000" "https://docs.python.org/3/ subpath 10000" \
 "https://www.tate.org.uk/kids/ subpath 3000" "https://www.nationalgallery.org.uk/ domain 10000" "https://www.metmuseum.org/ domain 10000" \
 "https://www.worldbank.org/en/ subpath 5000" "https://www.who.int/ domain 10000" "https://www.un.org/en/ subpath 10000" \
 "https://civilinitiatives.org/ domain 2000" "https://chausima.com/ domain 500" ; do set -- $s; crawl "$1" "$2" "$3"; done
