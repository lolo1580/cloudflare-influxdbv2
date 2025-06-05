#!/bin/bash

# InfluxDB v2 Configuration
InfluxDBURL="http://XXX.XXX.XXX.XXX"
InfluxDBPort="8086"
InfluxDBBucket="cloudflare"
InfluxDBOrg="ORGname"                 
InfluxDBToken="token"                 # DB Token 

# Cloudflare API credentials
cloudflareapikey="APItoken"           # Your API token
cloudflarezone="Zonetoken"            # Your Cloudflare zone Token
cloudflareemail="YourMail"            # Your Cloudflare Email

# Time range
back_seconds=$((60 * 60 * 24))  # 1 jour
end_epoch=$(date +'%s')
start_epoch=$((end_epoch - back_seconds))
start_date=$(date --date="@$start_epoch" +'%Y-%m-%d')
end_date=$(date --date="@$end_epoch" +'%Y-%m-%d')

# GraphQL Query (corrected structure: sum and uniq at same level)
read -r -d '' PAYLOAD <<EOF
{
  "query": "query { viewer { zones(filter: {zoneTag: \"$cloudflarezone\"}) { httpRequests1dGroups(limit:7, filter: {date_geq: \"$start_date\", date_leq: \"$end_date\"}) { dimensions { date } sum { bytes cachedBytes requests cachedRequests threats pageViews countryMap { clientCountryName requests } } uniq { uniques } } } } }"
}
EOF

cloudflareUrl=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Auth-Email: $cloudflareemail" \
  -H "X-Auth-Key: $cloudflareapikey" \
  --data "$PAYLOAD" \
  https://api.cloudflare.com/client/v4/graphql/)

# Check if the data exists
if ! echo "$cloudflareUrl" | jq -e '.data.viewer.zones[0].httpRequests1dGroups' >/dev/null; then
  echo "❌ Aucune donnée valide retournée par Cloudflare. Vérifie la période ou les identifiants."
  exit 1
fi

arraydays=0
for _ in $(echo "$cloudflareUrl" | jq -r '.data.viewer.zones[0].httpRequests1dGroups[].sum.requests'); do
  date_val=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].dimensions.date" <<< "$cloudflareUrl")
  cfTimeStamp=$(date -d "$date_val" '+%s')

  # Extract metrics
  cfBytes=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.bytes" <<< "$cloudflareUrl")
  cfCachedBytes=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.cachedBytes" <<< "$cloudflareUrl")
  cfRequests=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.requests" <<< "$cloudflareUrl")
  cfCachedRequests=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.cachedRequests" <<< "$cloudflareUrl")
  cfThreats=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.threats" <<< "$cloudflareUrl")
  cfPageViews=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.pageViews" <<< "$cloudflareUrl")
  cfUniques=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].uniq.uniques" <<< "$cloudflareUrl")

  # Build line protocol payload
  Payload="cloudflare,zone=$cloudflarezone bytes=$cfBytes,cached_bytes=$cfCachedBytes,requests=$cfRequests,cached_requests=$cfCachedRequests,threats=$cfThreats,pageviews=$cfPageViews,uniques=$cfUniques $cfTimeStamp"
  echo "$Payload"

  curl -i -X POST "${InfluxDBURL}:${InfluxDBPort}/api/v2/write?bucket=${InfluxDBBucket}&org=${InfluxDBOrg}&precision=s" \
    -H "Authorization: Token ${InfluxDBToken}" \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary "$Payload"

  # Country stats
  arraycountry=0
  for _ in $(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.countryMap[].clientCountryName" <<< "$cloudflareUrl"); do
    cfCountry=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.countryMap[$arraycountry].clientCountryName" <<< "$cloudflareUrl")
    [[ $cfCountry == "null" ]] && break
    cfCountryRequests=$(jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.countryMap[$arraycountry].requests" <<< "$cloudflareUrl")

    Payload="cloudflare,zone=$cloudflarezone,country=$cfCountry country_requests=$cfCountryRequests $cfTimeStamp"
    echo "$Payload"

    curl -i -X POST "${InfluxDBURL}:${InfluxDBPort}/api/v2/write?bucket=${InfluxDBBucket}&org=${InfluxDBOrg}&precision=s" \
      -H "Authorization: Token ${InfluxDBToken}" \
      -H "Content-Type: text/plain; charset=utf-8" \
      --data-binary "$Payload"

    arraycountry=$((arraycountry + 1))
  done

  arraydays=$((arraydays + 1))
done

# Test d'injection de point simple
curl -i -X POST "${InfluxDBURL}:${InfluxDBPort}/api/v2/write?bucket=${InfluxDBBucket}&org=${InfluxDBOrg}&precision=s" \
  -H "Authorization: Token ${InfluxDBToken}" \
  -H "Content-Type: text/plain; charset=utf-8" \
  --data-binary "cloudflare,zone=$cloudflarezone source=test debug=1 $(date +%s)"