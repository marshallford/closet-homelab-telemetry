#!/usr/bin/env bash
# Delete every annotation carrying the tag the dashboards query.
set -euo pipefail

: "${GRAFANA_URL:=http://localhost:3000}"
: "${GRAFANA_AUTH:=admin:admin}"
: "${ANNOTATION_TAG:=fan}"

while read -r id; do
  curl -sfg -u "$GRAFANA_AUTH" -X DELETE "$GRAFANA_URL/api/annotations/$id" > /dev/null
  echo "  deleted $id"
done < <(curl -sfg -u "$GRAFANA_AUTH" --get --data-urlencode "tags=$ANNOTATION_TAG" \
  "$GRAFANA_URL/api/annotations" | jq -r '.[].id')
