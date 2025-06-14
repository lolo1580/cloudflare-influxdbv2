#!/bin/bash
# cloudflare-analytics.sh - Cloudflare GraphQL to InfluxDB v2 (for Grafana)

# InfluxDB v2 Configuration
InfluxDBURL="http://xxx.xxx.xxx.xxx"
InfluxDBPort="8086"
InfluxDBBucket="yourbucketname"
InfluxDBToken="yourapitoken"
InfluxDBOrg="yourorgname"

# Cloudflare API Configuration
cloudflareapikey="Cloudflare global api token"
cloudflarezone="Your zone id API"
cloudflareemail="your Email"

# Time range (last 7 days)
back_seconds=$((60*60*24*7))
end_epoch=$(date +'%s')
start_epoch=$((end_epoch - back_seconds))
start_date=$(date --date="@$start_epoch" +'%Y-%m-%d')
end_date=$(date --date="@$end_epoch" +'%Y-%m-%d')

# GraphQL payload
PAYLOAD=$(cat <<EOF
{
  "query": "query { viewer { zones(filter: {zoneTag: \$zoneTag}) { httpRequests1dGroups(limit: 7, filter: \$filter) { dimensions { date } sum { browserMap { pageViews uaBrowserFamily } bytes cachedBytes cachedRequests contentTypeMap { bytes requests edgeResponseContentTypeName } countryMap { bytes requests threats clientCountryName } encryptedBytes encryptedRequests ipClassMap { requests ipType } pageViews requests responseStatusMap { requests edgeResponseStatus } threats threatPathingMap { requests threatPathingName } } uniq { uniques } } } } }",
  "variables": {
    "zoneTag": "$cloudflarezone",
    "filter": {
      "date_geq": "$start_date",
      "date_leq": "$end_date"
    }
  }
}
EOF
)

# Query Cloudflare GraphQL API
cloudflareUrl=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Auth-Email: $cloudflareemail" \
  -H "X-Auth-Key: $cloudflareapikey" \
  --data "$PAYLOAD" \
  https://api.cloudflare.com/client/v4/graphql/)

# Loop over days
declare -i arraydays=0
for requests in $(echo "$cloudflareUrl" | jq -r '.data.viewer.zones[0].httpRequests1dGroups[].sum.requests'); do
  cfRequestsAll=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.requests")
  if [[ "$cfRequestsAll" == "null" ]]; then break; fi

  cfRequestsCached=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.cachedRequests")
  cfRequestsUncached=$(echo "$cfRequestsAll - $cfRequestsCached" | bc)

  cfBandwidthAll=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.bytes")
  cfBandwidthCached=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.cachedBytes")
  cfBandwidthUncached=$(echo "$cfBandwidthAll - $cfBandwidthCached" | bc)

  cfThreatsAll=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.threats")
  cfPageviewsAll=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.pageViews")
  cfUniquesAll=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].uniq.uniques")
  date=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].dimensions.date")
  cfTimeStamp=$(date -d "$date" +%s)

  echo "Writing Zone data to InfluxDB (cloudflare_analytics)"
  curl -s -XPOST "$InfluxDBURL:$InfluxDBPort/api/v2/write?precision=s&bucket=$InfluxDBBucket&org=$InfluxDBOrg" \
    -H "Authorization: Token $InfluxDBToken" \
    --data-binary "cloudflare_analytics,cfZone=$cloudflarezone cfRequestsAll=$cfRequestsAll,cfRequestsCached=$cfRequestsCached,cfRequestsUncached=$cfRequestsUncached,cfBandwidthAll=$cfBandwidthAll,cfBandwidthCached=$cfBandwidthCached,cfBandwidthUncached=$cfBandwidthUncached,cfThreatsAll=$cfThreatsAll,cfPageviewsAll=$cfPageviewsAll,cfUniquesAll=$cfUniquesAll $cfTimeStamp"

  declare -i arraycountry=0
  for requests in $(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.countryMap[]?"); do
    cfRequestsCC=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.countryMap[$arraycountry].clientCountryName")
    if [[ "$cfRequestsCC" == "null" ]]; then break; fi

    cfRequests=$(echo "$cloudflareUrl" | jq -r ".data.viewer.zones[0].httpRequests1dGroups[$arraydays].sum.countryMap[$arraycountry].requests // \"0\"")

    echo "Writing Zone data per Country to InfluxDB (cloudflare_analytics_country)"
    curl -s -XPOST "$InfluxDBURL:$InfluxDBPort/api/v2/write?precision=s&bucket=$InfluxDBBucket&org=$InfluxDBOrg" \
      -H "Authorization: Token $InfluxDBToken" \
      --data-binary "cloudflare_analytics_country,country=$cfRequestsCC visits=$cfRequests $cfTimeStamp"

    arraycountry+=1
  done

  arraydays+=1
done
