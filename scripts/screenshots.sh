#!/usr/bin/env bash
# Render every provisioned dashboard, plus the panels worth showing alone.
set -euo pipefail

# Paths below are repo-relative, so anchor to the repo rather than the caller.
cd "$(dirname "$0")/.."

: "${GRAFANA_URL:=http://localhost:3000}"
: "${GRAFANA_AUTH:=admin:admin}"
: "${RENDER_FROM:=now-6h}"
: "${RENDER_TO:=now}"
: "${RENDER_PANELS:=Temperature by sensor}"

params="hideLogo=true&scale=2&from=$RENDER_FROM&to=$RENDER_TO"
images=docs/images

pids=()

# Renders are independent and mostly spent waiting on the browser, so start
# them all and collect the exit statuses afterwards.
render() {
  local out=$1 url=$2
  echo "  $out"
  curl -sfg -u "$GRAFANA_AUTH" -o "$out" "$url" &
  pids+=("$!")
}

mkdir -p "$images"

for json in dashboards/rendered/*.json; do
  uid=$(basename "$json" .json)

  # A grid row is 38px. The rest is dashboard chrome, plus a bottom margin to
  # match the gutters on the other three sides.
  height=$(jq '[.panels[] | .gridPos.y + .gridPos.h] | max * 38 + 72' "$json")
  render "$images/$uid.png" \
    "$GRAFANA_URL/render/d/$uid/$uid?width=1600&height=$height&kiosk&$params"

  # Process substitution rather than a pipe, so a failed render aborts the run
  # instead of being swallowed by the loop's exit status.
  while IFS=$'\t' read -r id title; do
    slug=$(echo "$title" | tr -d '/' | tr 'A-Z ' 'a-z-')
    render "$images/$uid-$slug.png" \
      "$GRAFANA_URL/render/d-solo/$uid/$uid?panelId=$id&width=1600&height=500&$params"
  done < <(jq -r --arg re "$RENDER_PANELS" \
    '.panels[] | select(.type != "row") | select(.title | test($re)) | "\(.id)\t\(.title)"' \
    "$json")
done

# Waiting on each pid in turn propagates a failure; a bare wait would not.
for pid in "${pids[@]}"; do
  wait "$pid"
done
