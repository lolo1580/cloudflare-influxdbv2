#!/bin/bash
set -Eeuo pipefail
echo "Running: $(readlink -f "$0")"

# ============== InfluxDB v2 ==============
InfluxDBURL="http://192.168.xx.xx"
InfluxDBPort="8086"
InfluxDBBucket="__BUCKET_NAME__"
InfluxDBOrg="__ORG_NAME__"
InfluxDBToken="__INFLUX_TOKEN__"   # ← remplace

# ============== Cloudflare ==============
# recommandé : API Token (scope Zone:Analytics:Read sur keller-laurent.org)
CLOUDFLARE_API_TOKEN="__DEDICATED_API_TOKEN__"

# fallback si tu n’utilises pas d’API token :
CLOUDFLARE_GLOBAL_API_KEY=""
CLOUDFLARE_EMAIL="__YOURMAIL__"

# zone tag
CLOUDFLARE_ZONE_TAG="__ZONEID__"

# ============== Fenêtre ==============
DAYS=7   # mets 1 si ton bucket a une rétention courte

# ============== Dépendances ==============
need() { command -v "$1" >/dev/null 2>&1 || { echo "Manque dépendance: $1"; exit 1; }; }
need jq
need curl
need date

# ============== Helpers ==============
escape_tag() { sed -e 's/\\/\\\\/g' -e 's/,/\\,/g' -e 's/=/\\=/g' -e 's/ /\\ /g'; }

write_influx() {
  local line="$1"
  local url="${InfluxDBURL}:${InfluxDBPort}/api/v2/write?org=${InfluxDBOrg}&bucket=${InfluxDBBucket}&precision=s"
  local resp code body
  resp=$(curl -s -w "\n%{http_code}" -XPOST "$url" \
    -H "Authorization: Token ${InfluxDBToken}" \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary "$line")
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$code" != "204" ]]; then
    echo "Influx write HTTP: $code — $body"
  else
    echo "Influx write HTTP: 204"
  fi
}

cf_call() {
  local payload="$1"
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && "$CLOUDFLARE_API_TOKEN" != "__CLOUDFLARE_API_TOKEN__" ]]; then
    curl -sS -X POST "https://api.cloudflare.com/client/v4/graphql" \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --data "$payload"
  else
    curl -sS -X POST "https://api.cloudflare.com/client/v4/graphql" \
      -H 'Content-Type: application/json' \
      -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
      -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}" \
      --data "$payload"
  fi
}

# ============== GraphQL (adaptive) ==============
GRAPHQL_QUERY='query($zoneTag: String!, $ts: Date) {
  viewer {
    zones(filter: {zoneTag: $zoneTag}) {
      series: httpRequestsAdaptiveGroups(
        limit: 5000,
        orderBy: [count_DESC],
        filter: { date: $ts }
      ) {
        count
        sum { edgeResponseBytes visits }
        dimensions { clientCountryName }
      }
    }
  }
}'

do_day() {
  local the_date="$1"          # YYYY-MM-DD
  local ts
  ts=$(date -u -d "${the_date} 12:00:00" +%s)  # 12:00 UTC (plus visible dans l’UI)

  # payload JSON compact
  local payload
  payload=$(jq -n --arg q "$GRAPHQL_QUERY" --arg z "$CLOUDFLARE_ZONE_TAG" --arg t "$the_date" \
            '{query:$q, variables:{zoneTag:$z, ts:$t}}')

  # appel Cloudflare
  local resp
  resp=$(cf_call "$payload")

  # erreurs GraphQL ?
  if [[ "$(echo "$resp" | jq '.errors|length // 0')" -gt 0 ]]; then
    echo "Cloudflare GraphQL errors for $the_date:"
    echo "$resp" | jq '.errors'
    return 1
  fi

  local base='.data.viewer.zones[0].series'
  local len
  len=$(echo "$resp" | jq "$base | length")
  [[ "$len" -eq 0 ]] && { echo "No data for $the_date"; return 0; }

  # Totaux jour (somme des pays)
  local req_all bw_all visits_all
  req_all=$(   echo "$resp" | jq -r "$base | map(.count) | add // 0")
  bw_all=$(    echo "$resp" | jq -r "$base | map(.sum.edgeResponseBytes) | add // 0")
  visits_all=$(echo "$resp" | jq -r "$base | map(.sum.visits) | add // 0")
  [[ "$bw_all" =~ ^[0-9]+$ ]] && bw_all="${bw_all}.0"

  echo "Write totals $the_date"
  write_influx "cloudflare_analytics,cfZone=${CLOUDFLARE_ZONE_TAG} cfRequestsAll=${req_all}i,cfBandwidthAll=${bw_all},cfVisits=${visits_all}i ${ts}"

  # Détail par pays
  local j cc cc_tag reqs bytes visits
  for ((j=0; j<len; j++)); do
    cc=$(echo "$resp" | jq -r "$base[$j].dimensions.clientCountryName // empty")
    [[ -z "$cc" ]] && continue
    cc_tag=$(printf "%s" "$cc" | escape_tag)
    reqs=$(  echo "$resp" | jq -r "$base[$j].count // 0")
    bytes=$( echo "$resp" | jq -r "$base[$j].sum.edgeResponseBytes // 0")
    visits=$(echo "$resp" | jq -r "$base[$j].sum.visits // 0")
    [[ "$bytes" =~ ^[0-9]+$ ]] && bytes="${bytes}.0"

    write_influx "cloudflare_analytics_country,cfZone=${CLOUDFLARE_ZONE_TAG},country=${cc_tag} requests=${reqs}i,bandwidth=${bytes},visits=${visits}i ${ts}"
  done
}

# ============== Boucle des N derniers jours ==============
for i in $(seq 0 $((DAYS-1))); do
  day=$(date -u -d "-${i} day" +'%Y-%m-%d')
  do_day "$day"
done

echo "Done."
