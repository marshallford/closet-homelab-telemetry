#!/usr/bin/env bash
# Average a window either side of a change and print the difference.
set -euo pipefail

: "${PROMETHEUS_URL:=http://localhost:9090}"
: "${GRAFANA_URL:=http://localhost:3000}"
: "${GRAFANA_AUTH:=admin:admin}"
: "${ANNOTATION_TAG:=fan}"
: "${COMPARE_WINDOW:=1}"
: "${COMPARE_SETTLE:=0.5}"
: "${COMPARE_AT:=}"
: "${COMPARE_HOST:=}"
: "${COMPARE_SENSOR:=}"
: "${COMPARE_POWER:=}"

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

indent() { awk '{ print "  " $0 }'; }

# Auto when there is only one, named otherwise. Picking the first of several
# would quietly measure the wrong thing, so anything ambiguous stops and lists
# what it could have meant.
choose() { # variable name, current value, newline-separated options
  local var=$1 want=$2 opts=$3
  if [ -z "$want" ]; then
    [ "$(grep -c . <<< "$opts")" -eq 1 ] || die "set $var to one of:
$(indent <<< "$opts")"
    printf '%s' "$opts"
    return
  fi
  grep -qxF -- "$want" <<< "$opts" || die "no $var matching $want. Options:
$(indent <<< "$opts")"
  printf '%s' "$want"
}

# Prometheus answers 200 with status "success" for a query that matched
# nothing, so a transport failure, a rejected query and an empty result have to
# be told apart deliberately. -f is absent on purpose: a 400 carries the reason
# for the rejection in its body.
prom() {
  local body
  body=$(curl -sg --max-time 15 "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode "query=$1" --data-urlencode "time=$2") ||
    die "cannot reach Prometheus at $PROMETHEUS_URL"
  jq -e '.status == "success"' <<< "$body" > /dev/null ||
    die "Prometheus rejected a query: $(jq -r '.error // "no reason given"' <<< "$body")"
  printf '%s' "$body"
}

# One value, or nothing. Absence prints an empty string rather than a zero: a
# missing sensor and a sensor reading zero are different answers, and only one
# of them is a measurement.
value() {
  prom "$1" "$2" | jq -r '.data.result[0].value[1] // empty'
}

# Every sensor each metric had in the before window. Grouping collapses
# duplicate series that a collector restart can leave inside the lookback.
#
# Temperatures are normalized and carry hw.id; power stays source-native and
# keeps the hwmon chip and sensor, so the two are identified differently.
temp_sensors() {
  prom "max by (hw_id) (avg_over_time(hw_temperature_celsius${sel}[$w]))" "$at" |
    jq -r '.data.result[].metric.hw_id // empty'
}

power_sensors() {
  prom "max by (chip, sensor) (avg_over_time(node_hwmon_power_watt${sel}[$w]))" "$at" |
    jq -r '.data.result[].metric | "\(.chip)/\(.sensor)"'
}

# The change being measured is the one that was annotated, so default to the
# most recent mark rather than asking for the time twice.
if [ -z "$COMPARE_AT" ]; then
  ms=$(curl -sfg -u "$GRAFANA_AUTH" --get --data-urlencode "tags=$ANNOTATION_TAG" \
    "$GRAFANA_URL/api/annotations" | jq -r 'max_by(.time).time // 0') ||
    die "cannot read annotations from $GRAFANA_URL"
  [ "$ms" != 0 ] || die "no annotation tagged $ANNOTATION_TAG; set COMPARE_AT"
  COMPARE_AT="@$((ms / 1000))"
fi
at=$(date -d "$COMPARE_AT" +%s) || die "cannot parse COMPARE_AT=$COMPARE_AT"

# A PromQL duration is an integer and a unit, so the window is whole hours.
# COMPARE_SETTLE only shifts a timestamp, so it can be fractional.
case $COMPARE_WINDOW in
  '' | *[!0-9]* | 0) die "COMPARE_WINDOW must be a whole number of hours, not $COMPARE_WINDOW" ;;
esac
w="${COMPARE_WINDOW}h"
begin=$((at - COMPARE_WINDOW * 3600))
after=$(awk -v a="$at" -v w="$COMPARE_WINDOW" -v s="$COMPARE_SETTLE" \
  'BEGIN { printf "%d", a + (w + s) * 3600 }')

[ "$after" -le "$(date +%s)" ] ||
  echo "warning: the after window ends $(date -d "@$after" '+%H:%M'), which has not happened yet" >&2

# Scoped to the window being compared, so a machine that reported last week but
# is gone now does not count as a second host.
hosts=$(curl -sfg --get --max-time 15 "$PROMETHEUS_URL/api/v1/label/host_name/values" \
  --data-urlencode "match[]=system_uptime_seconds" \
  --data-urlencode "start=$begin" --data-urlencode "end=$after" \
  | jq -r '.data[]?') || die "cannot reach Prometheus at $PROMETHEUS_URL"
COMPARE_HOST=$(choose COMPARE_HOST "$COMPARE_HOST" "$hosts")
sel="{host_name=\"$COMPARE_HOST\"}"

# A window with a hole in it still averages, over fewer samples than asked for.
# Comparing the two counts catches that without assuming a scrape interval.
nb=$(value "count_over_time(system_uptime_seconds${sel}[$w])" "$at")
na=$(value "count_over_time(system_uptime_seconds${sel}[$w])" "$after")
[ -n "$nb" ] || die "no samples for $COMPARE_HOST in the $w before $(date -d "@$at" '+%Y-%m-%d %H:%M')"
[ -n "$na" ] || die "no samples for $COMPARE_HOST in the $w ending $(date -d "@$after" '+%Y-%m-%d %H:%M')"
awk -v b="$nb" -v a="$na" 'BEGIN {
  m = (b > a ? b : a)
  if (m == 0 || (m - (b < a ? b : a)) / m > 0.1)
    printf "warning: uneven coverage, %d samples before and %d after\n", b, a
}' >&2

# Named, not guessed, so both windows describe the same piece of hardware.
COMPARE_SENSOR=$(choose COMPARE_SENSOR "$COMPARE_SENSOR" "$(temp_sensors)")

# A host with no power sensor still gets a temperature and a CPU reading.
powers=$(power_sensors)
[ -z "$powers" ] || COMPARE_POWER=$(choose COMPARE_POWER "$COMPARE_POWER" "$powers")

reading() { # metric, label selector, time
  value "max(avg_over_time(${1}{host_name=\"$COMPARE_HOST\", $2}[$w]))" "$3"
}

tb=$(reading hw_temperature_celsius "hw_id=\"$COMPARE_SENSOR\"" "$at")
ta=$(reading hw_temperature_celsius "hw_id=\"$COMPARE_SENSOR\"" "$after")
[ -n "$tb" ] || die "sensor $COMPARE_SENSOR has no readings in the before window"

if [ -n "$COMPARE_POWER" ]; then
  # chip/sensor, split back into the labels the source-native metric carries.
  psel="chip=\"${COMPARE_POWER%%/*}\", sensor=\"${COMPARE_POWER##*/}\""
  pb=$(reading node_hwmon_power_watt "$psel" "$at")
  pa=$(reading node_hwmon_power_watt "$psel" "$after")
fi

# Power and CPU are controls: a temperature drop only means something if the
# machine was doing comparable work on both sides.
cpu="1 - (sum(rate(system_cpu_time_seconds_total{host_name=\"$COMPARE_HOST\", state=\"idle\"}[$w])) / scalar(max(system_cpu_logical_count$sel)))"
cb=$(value "$cpu" "$at")
ca=$(value "$cpu" "$after")

# A side that is missing prints "-"; one that is present is still formatted,
# so a half-empty row keeps its columns.
row() {
  printf '%-26s' "$1"
  awk -v b="${2:-}" -v a="${3:-}" 'BEGIN {
    bs = (b == "") ? "-" : sprintf("%.2f", b)
    as = (a == "") ? "-" : sprintf("%.2f", a)
    ds = (b == "" || a == "") ? "-" : sprintf("%+.2f", a - b)
    printf " %9s %9s %9s\n", bs, as, ds
  }'
}

printf '%s, %s before %s vs %s ending %s (%s/%s samples)\n' \
  "$COMPARE_HOST" "$w" "$(date -d "@$at" '+%Y-%m-%d %H:%M')" \
  "$w" "$(date -d "@$after" '+%H:%M')" "$nb" "$na"
printf 'sensor %s\n' "$COMPARE_SENSOR"
[ -z "$COMPARE_POWER" ] || printf 'power  %s\n' "$COMPARE_POWER"

printf '\n%-26s %9s %9s %9s\n' metric before after delta
row 'temperature (C)' "$tb" "$ta"
[ -z "$COMPARE_POWER" ] || row 'power (W)' "${pb:-}" "${pa:-}"
row 'cpu busy' "$cb" "$ca"
