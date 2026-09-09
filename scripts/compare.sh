#!/usr/bin/env bash
# Average a window either side of a change and print the difference.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${GRAFANA_URL:=http://localhost:3000}"
: "${GRAFANA_AUTH:=admin:admin}"
: "${PROMETHEUS_URL:=http://localhost:9090}"
: "${ANNOTATION_TAG:=fan}"
: "${COMPARE_WINDOW:=3}"
: "${COMPARE_SETTLE:=0}"
: "${COMPARE_AT:=}"
: "${COMPARE_HOST:=}"

# The change being measured is the one that was annotated, so default to the
# most recent mark rather than asking for the time twice.
if [ -z "$COMPARE_AT" ]; then
  ms=$(curl -sfg -u "$GRAFANA_AUTH" --get --data-urlencode "tags=$ANNOTATION_TAG" \
    "$GRAFANA_URL/api/annotations" | jq -r 'max_by(.time).time // 0')
  [ "$ms" != 0 ] || { echo "no annotation tagged $ANNOTATION_TAG; set COMPARE_AT" >&2; exit 1; }
  COMPARE_AT="@$((ms / 1000))"
fi
at=$(date -d "$COMPARE_AT" +%s)
after=$(awk -v a="$at" -v w="$COMPARE_WINDOW" -v s="$COMPARE_SETTLE" \
  'BEGIN { printf "%d", a + (w + s) * 3600 }')

if [ -z "$COMPARE_HOST" ]; then
  COMPARE_HOST=$(curl -sfg "$PROMETHEUS_URL/api/v1/label/host_name/values" | jq -r '.data[0]')
fi
sel="{host_name=\"$COMPARE_HOST\"}"
w="${COMPARE_WINDOW}h"

query() {
  curl -sfg "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode "query=$1" --data-urlencode "time=$2" \
    | jq -r '.data.result[0].value[1] // "0"'
}

[ "$after" -le "$(date +%s)" ] ||
  echo "warning: the after window ends $(date -d "@$after" '+%H:%M'), which has not happened yet" >&2

# A window with a hole in it still averages, just over less than you asked
# for. Comparing the two counts catches that without assuming an interval.
nb=$(query "count_over_time(system_uptime_seconds${sel}[$w])" "$at")
na=$(query "count_over_time(system_uptime_seconds${sel}[$w])" "$after")
awk -v b="$nb" -v a="$na" 'BEGIN {
  m = (b > a ? b : a)
  if (m == 0 || (m - (b < a ? b : a)) / m > 0.1)
    printf "warning: uneven coverage, %d samples before and %d after\n", b, a
}' >&2

printf '%s, %s before %s and %s ending %s (%s/%s samples)\n\n' \
  "$COMPARE_HOST" "$w" "$(date -d "@$at" '+%Y-%m-%d %H:%M')" \
  "$w" "$(date -d "@$after" '+%H:%M')" "$nb" "$na"
printf '%-18s %10s %10s %10s\n' metric before after delta

# Averaging each series over raw samples, then aggregating, avoids a subquery
# whose resolution would silently shift the answer. Power and CPU are
# controls: a temperature drop only means something if the machine was doing
# comparable work on both sides.
while IFS='|' read -r label expr; do
  b=$(query "$expr" "$at")
  a=$(query "$expr" "$after")
  awk -v l="$label" -v b="$b" -v a="$a" \
    'BEGIN { printf "%-18s %10.2f %10.2f %+10.2f\n", l, b, a, a - b }'
done <<EOF
hottest (C)|max(avg_over_time(hw_temperature_celsius${sel}[$w]))
degrees per watt|max(avg_over_time(hw_temperature_celsius${sel}[$w])) / scalar(max(avg_over_time(hw_power_watts${sel}[$w])))
package (W)|max(avg_over_time(hw_power_watts${sel}[$w]))
cpu busy|1 - (sum(rate(system_cpu_time_seconds_total{host_name="$COMPARE_HOST", state="idle"}[$w])) / scalar(max(system_cpu_logical_count$sel)))
EOF
