#!/bin/bash
# Chausima Mail: show recent outbound delivery events (no secrets printed)
L=/mnt/launchpad-data/stalwart/logs
cat $L/stalwart.log.* 2>/dev/null | grep -E "\((delivery|queue)\.[a-z.-]+\)" | grep -viE "password|secret|token" | tail -${1:-6} | sed -E 's/queueId = [0-9]+, //' | fold -w 170
echo "--- event counts"
cat $L/stalwart.log.* 2>/dev/null | grep -oE "\((delivery|queue)\.[a-z.-]+\)" | sort | uniq -c | sort -rn | head
