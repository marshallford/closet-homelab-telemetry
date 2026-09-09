#!/usr/bin/env bash
# Record an intervention on the dashboards' annotation layer.
set -euo pipefail

: "${GRAFANA_URL:=http://localhost:3000}"
: "${GRAFANA_AUTH:=admin:admin}"
: "${ANNOTATION_TAG:=fan}"
: "${ANNOTATION_TAGS:=}"
: "${ANNOTATION_AT:=now}"
: "${ANNOTATION_UNTIL:=}"

text=${1:-${ANNOTATION:-}}
if [ -z "$text" ]; then
  echo "usage: ${0##*/} <text>, or ANNOTATION=<text>" >&2
  exit 1
fi

# Grafana takes epoch milliseconds; date -d accepts anything GNU parses,
# so an intervention can be recorded after the fact.
at=$(date -d "$ANNOTATION_AT" +%s)000

# With no end the annotation is an instant. Given one it becomes a region,
# which is what an interval like "fan running" should look like.
until=
if [ -n "$ANNOTATION_UNTIL" ]; then
  until=$(date -d "$ANNOTATION_UNTIL" +%s)000
  if [ "$until" -le "$at" ]; then
    echo "ANNOTATION_UNTIL must be after ANNOTATION_AT" >&2
    exit 1
  fi
fi

# ANNOTATION_TAG is the layer the dashboards query, so it is always present.
# ANNOTATION_TAGS rides alongside it: a tag query matches on any subset, so
# extra tags narrow a search without hiding the annotation from the panels.
body=$(jq -nc \
  --arg text "$text" \
  --arg tag "$ANNOTATION_TAG" \
  --arg extra "$ANNOTATION_TAGS" \
  --argjson at "$at" \
  --arg until "$until" \
  '{
    text: $text,
    tags: [$tag] + ($extra | split(" ") | map(select(. != ""))),
    time: $at,
  }
  + (if $until == "" then {} else { timeEnd: ($until | tonumber) } end)')

curl -sfg -u "$GRAFANA_AUTH" -H 'Content-Type: application/json' -d "$body" \
  "$GRAFANA_URL/api/annotations" \
  | jq -r '"\(.id)\t\(.message)"'
