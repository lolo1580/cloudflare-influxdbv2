#!/bin/bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ============== InfluxDB v2 ==============
InfluxDBURL="http://192.168.xx.xx"
InfluxDBPort="8086"
InfluxDBBucket="__BUCKET_NAME__"
InfluxDBOrg="__ORG_NAME__"
InfluxDBToken="__INFLUX_TOKEN__"

# ============== Cloudflare ==============
CLOUDFLARE_API_TOKEN="__DEDICATED_API_TOKEN__"
CLOUDFLARE_GLOBAL_API_KEY=""
CLOUDFLARE_EMAIL="__YOURMAIL__"
CLOUDFLARE_ZONE_TAG="__ZONEID__"

# ============== Collection ==============
DAYS=1
TOP_N=20
ENABLE_CACHE_METRICS=true
ENABLE_STATUS_METRICS=true
ENABLE_THREAT_METRICS=true
ENABLE_TOP_PATHS=true
ENABLE_USER_AGENTS=false
ENABLE_CONTENT_TYPES=true

# ============== Dependencies ==============
need() { command -v "$1" >/dev/null 2>&1 || { log_error "Missing dependency: $1"; exit 1; }; }
need jq
need curl
need date
need sed

# ============== Helpers ==============
is_placeholder() {
  [[ "$1" == __*__ ]]
}

is_enabled() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]] || is_placeholder "$value"; then
    log_error "Missing configuration: ${name}"
    exit 1
  fi
}

validate_config() {
  require_value "InfluxDBURL" "$InfluxDBURL"
  require_value "InfluxDBPort" "$InfluxDBPort"
  require_value "InfluxDBBucket" "$InfluxDBBucket"
  require_value "InfluxDBOrg" "$InfluxDBOrg"
  require_value "InfluxDBToken" "$InfluxDBToken"
  require_value "CLOUDFLARE_ZONE_TAG" "$CLOUDFLARE_ZONE_TAG"

  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && ! is_placeholder "$CLOUDFLARE_API_TOKEN"; then
    return 0
  fi

  require_value "CLOUDFLARE_EMAIL" "$CLOUDFLARE_EMAIL"
  require_value "CLOUDFLARE_GLOBAL_API_KEY" "$CLOUDFLARE_GLOBAL_API_KEY"
}

escape_influx_tag() {
  sed -e 's/\\/\\\\/g' -e 's/,/\\,/g' -e 's/=/\\=/g' -e 's/ /\\ /g'
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

graphql_payload() {
  local query="$1"
  local variables_json="$2"
  jq -n --arg q "$query" --argjson v "$variables_json" '{query:$q, variables:$v}'
}

graphql_query() {
  local name="$1"
  local query="$2"
  local variables_json="$3"
  local payload resp code body

  payload=$(graphql_payload "$query" "$variables_json")

  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && ! is_placeholder "$CLOUDFLARE_API_TOKEN"; then
    resp=$(curl -sS -w "\n%{http_code}" -X POST "https://api.cloudflare.com/client/v4/graphql" \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --data "$payload")
  else
    resp=$(curl -sS -w "\n%{http_code}" -X POST "https://api.cloudflare.com/client/v4/graphql" \
      -H 'Content-Type: application/json' \
      -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
      -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}" \
      --data "$payload")
  fi

  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$code" != "200" ]]; then
    log_error "${name}: Cloudflare HTTP ${code}"
    printf '%s\n' "$body"
    return 1
  fi

  printf '%s\n' "$body"
}

graphql_check_errors() {
  local name="$1"
  local severity="$2"
  local response="$3"
  local errors

  errors=$(jq -r '
    .errors // [] |
    map(
      .message
      + (if .path then " (path: " + (.path | join(".")) + ")" else "" end)
    ) |
    join("; ")
  ' <<<"$response")

  if [[ -n "$errors" ]]; then
    if [[ "$severity" == "fatal" ]]; then
      log_error "${name}: ${errors}"
    else
      log_warn "${name}: ${errors}"
    fi
    return 1
  fi

  return 0
}

write_influx() {
  local measurement="$1"
  local line="$2"
  local url resp code body

  url="${InfluxDBURL}:${InfluxDBPort}/api/v2/write?org=$(urlencode "$InfluxDBOrg")&bucket=$(urlencode "$InfluxDBBucket")&precision=s"
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$url" \
    -H "Authorization: Token ${InfluxDBToken}" \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary "$line")
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$code" != "204" ]]; then
    log_error "InfluxDB write failed for ${measurement}: HTTP ${code}"
    [[ -n "$body" ]] && log_error "$body"
    return 1
  fi

  log_info "InfluxDB write ${measurement}: HTTP 204"
}

write_point() {
  local measurement="$1"
  local tags="$2"
  local fields="$3"
  local timestamp="$4"
  write_influx "$measurement" "${measurement},${tags} ${fields} ${timestamp}"
}

escape_tag_value() {
  printf '%s' "$1" | escape_influx_tag
}

day_bounds() {
  local day="$1"
  local start end
  start=$(date -u -d "${day} 00:00:00" +'%Y-%m-%dT%H:%M:%SZ')
  end=$(date -u -d "${day} 00:00:00 +1 day" +'%Y-%m-%dT%H:%M:%SZ')
  printf '%s\t%s\n' "$start" "$end"
}

day_timestamp() {
  local day="$1"
  date -u -d "${day} 12:00:00" +%s
}

read_country_groups() {
  local response="$1"
  jq -r '
    .data.viewer.zones[0].series // [] |
    map({
      country: (.dimensions.clientCountryName // ""),
      requests: (.count // 0),
      bandwidth: (.sum.edgeResponseBytes // 0),
      visits: (.sum.visits // 0)
    }) |
    .[]
    | select(.country != "")
    | [.country, (.requests|tostring), (.bandwidth|tostring), (.visits|tostring)]
    | @tsv
  ' <<<"$response"
}

read_top_groups() {
  local response="$1"
  local dimension_key="$2"
  jq -r --arg dimension_key "$dimension_key" '
    .data.viewer.zones[0].series // [] |
    map({
      tag: (.dimensions[$dimension_key] // ""),
      requests: (.count // 0),
      bandwidth: (.sum.edgeResponseBytes // 0),
      visits: (.sum.visits // 0)
    }) |
    .[]
    | select(.tag != "")
    | [.tag, (.requests|tostring), (.bandwidth|tostring), (.visits|tostring)]
    | @tsv
  ' <<<"$response"
}

read_http_1m_totals() {
  local response="$1"
  jq -r '
    .data.viewer.zones[0].series // [] |
    reduce .[] as $row (
      {
        requests: 0,
        bytes: 0,
        cached_requests: 0,
        cached_bytes: 0,
        threats: 0,
        pageviews: 0
      };
      .requests += ($row.sum.requests // 0) |
      .bytes += ($row.sum.bytes // 0) |
      .cached_requests += ($row.sum.cachedRequests // 0) |
      .cached_bytes += ($row.sum.cachedBytes // 0) |
      .threats += ($row.sum.threats // 0) |
      .pageviews += ($row.sum.pageViews // 0)
    ) |
    [.requests, .bytes, .cached_requests, .cached_bytes, .threats, .pageviews]
    | @tsv
  ' <<<"$response"
}

read_status_rows() {
  local response="$1"
  jq -r '
    .data.viewer.zones[0].series // [] |
    [ .[].sum.responseStatusMap[]? ] |
    sort_by(.edgeResponseStatus) |
    group_by(.edgeResponseStatus) |
    map({
      status: (.[0].edgeResponseStatus // 0),
      requests: (map(.requests // 0) | add // 0)
    }) |
    .[]
    | [(.status|tostring), (.requests|tostring)]
    | @tsv
  ' <<<"$response"
}

read_content_type_rows() {
  local response="$1"
  jq -r '
    .data.viewer.zones[0].series // [] |
    [ .[].sum.contentTypeMap[]? ] |
    sort_by(.edgeResponseContentTypeName) |
    group_by(.edgeResponseContentTypeName) |
    map({
      content_type: .[0].edgeResponseContentTypeName,
      requests: (map(.requests // 0) | add // 0),
      bytes: (map(.bytes // 0) | add // 0)
    }) |
    .[]
    | [(.content_type|tostring), (.requests|tostring), (.bytes|tostring)]
    | @tsv
  ' <<<"$response"
}

aggregate_top_rows() {
  local response="$1"
  local max_rows="$2"
  jq -r --argjson max_rows "$max_rows" '
    .data.viewer.zones[0].series // [] |
    .[0:$max_rows] |
    .[]
    | [
        (.dimensions.clientRequestHTTPHost // ""),
        (.dimensions.clientRequestPath // ""),
        (.dimensions.userAgent // ""),
        (.count // 0),
        (.sum.edgeResponseBytes // 0),
        (.sum.visits // 0)
      ]
    | @tsv
  ' <<<"$response"
}

build_query() {
  local query="$1"
  local zone_tag="$2"
  local start="$3"
  local end="$4"
  local limit="$5"
  jq -n \
    --arg q "$query" \
    --arg zoneTag "$zone_tag" \
    --arg start "$start" \
    --arg end "$end" \
    --argjson limit "$limit" \
    '{query:$q, variables:{zoneTag:$zoneTag, start:$start, end:$end, limit:$limit}}'
}

collect_totals() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag ts response line row requests bandwidth visits
  local query

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")
  ts=$(day_timestamp "$day")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequestsAdaptiveGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
        orderBy: [count_DESC]
      ) {
        count
        sum {
          edgeResponseBytes
          visits
        }
        dimensions {
          clientCountryName
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_totals" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "5000")") || return 1
  graphql_check_errors "collect_totals" fatal "$response" || return 1

  row=$(jq -r '
    .data.viewer.zones[0].series // [] |
    reduce .[] as $row (
      {requests: 0, bandwidth: 0, visits: 0};
      .requests += ($row.count // 0) |
      .bandwidth += ($row.sum.edgeResponseBytes // 0) |
      .visits += ($row.sum.visits // 0)
    ) |
    [.requests, .bandwidth, .visits] | @tsv
  ' <<<"$response")

  IFS=$'\t' read -r requests bandwidth visits <<<"$row"
  [[ -z "${requests:-}" ]] && requests=0
  [[ -z "${bandwidth:-}" ]] && bandwidth=0
  [[ -z "${visits:-}" ]] && visits=0

  line="cfRequestsAll=${requests}i,cfBandwidthAll=${bandwidth},cfVisits=${visits}i"
  write_point "cloudflare_analytics" "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day")" "$line" "$ts"
}

collect_countries() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response line country requests bandwidth visits query
  local timestamp

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")
  timestamp=$(day_timestamp "$day")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequestsAdaptiveGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
        orderBy: [count_DESC]
      ) {
        count
        sum {
          edgeResponseBytes
          visits
        }
        dimensions {
          clientCountryName
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_countries" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "5000")") || {
    log_warn "collect_countries skipped"
    return 0
  }

  if ! graphql_check_errors "collect_countries" warn "$response"; then
    return 0
  fi

  while IFS=$'\t' read -r country requests bandwidth visits; do
    [[ -z "${country:-}" ]] && continue
    line="requests=${requests}i,bandwidth=${bandwidth},visits=${visits}i"
    write_point "cloudflare_analytics_country" "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),country=$(escape_tag_value "$country")" "$line" "$timestamp"
  done < <(read_country_groups "$response")
}

collect_cache() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response row requests bytes cached_requests cached_bytes hit_requests miss_requests hit_bytes miss_bytes timestamp query

  if ! is_enabled "$ENABLE_CACHE_METRICS"; then
    return 0
  fi

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")
  timestamp=$(day_timestamp "$day")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequests1mGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
      ) {
        sum {
          requests
          bytes
          cachedRequests
          cachedBytes
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_cache" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "5000")") || {
    log_warn "collect_cache skipped"
    return 0
  }

  if ! graphql_check_errors "collect_cache" warn "$response"; then
    return 0
  fi

  row=$(read_http_1m_totals "$response") || {
    log_warn "collect_cache skipped"
    return 0
  }

  IFS=$'\t' read -r requests bytes cached_requests cached_bytes _ <<<"$row"
  hit_requests=${cached_requests:-0}
  hit_bytes=${cached_bytes:-0}
  miss_requests=$(( ${requests:-0} - ${cached_requests:-0} ))
  miss_bytes=$(( ${bytes:-0} - ${cached_bytes:-0} ))

  write_point "cloudflare_analytics_cache" \
    "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),cache_status=hit" \
    "requests=${hit_requests}i,bandwidth=${hit_bytes}" \
    "$timestamp"

  write_point "cloudflare_analytics_cache" \
    "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),cache_status=miss" \
    "requests=${miss_requests}i,bandwidth=${miss_bytes}" \
    "$timestamp"
}

collect_status_codes() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response timestamp query

  if ! is_enabled "$ENABLE_STATUS_METRICS"; then
    return 0
  fi

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")
  timestamp=$(day_timestamp "$day")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequests1mGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
      ) {
        sum {
          responseStatusMap {
            edgeResponseStatus
            requests
          }
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_status_codes" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "5000")") || {
    log_warn "collect_status_codes skipped"
    return 0
  }

  if ! graphql_check_errors "collect_status_codes" warn "$response"; then
    return 0
  fi

  while IFS=$'\t' read -r status requests; do
    [[ -z "${status:-}" ]] && continue
    write_point "cloudflare_analytics_status" \
      "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),status=$(escape_tag_value "$status")" \
      "requests=${requests}i" \
      "$timestamp"
  done < <(read_status_rows "$response")
}

collect_threats() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response timestamp row threats query

  if ! is_enabled "$ENABLE_THREAT_METRICS"; then
    return 0
  fi

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")
  timestamp=$(day_timestamp "$day")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequests1mGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
      ) {
        sum {
          threats
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_threats" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "5000")") || {
    log_warn "collect_threats skipped"
    return 0
  }

  if ! graphql_check_errors "collect_threats" warn "$response"; then
    return 0
  fi

  row=$(jq -r '
    .data.viewer.zones[0].series // [] |
    reduce .[] as $row (0; . + ($row.sum.threats // 0)) | tostring
  ' <<<"$response")

  threats=${row:-0}
  write_point "cloudflare_analytics_threats" \
    "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day")" \
    "threats=${threats}i" \
    "$timestamp"
}

collect_hostnames() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response query

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequestsAdaptiveGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
        orderBy: [count_DESC]
      ) {
        count
        sum {
          edgeResponseBytes
          visits
        }
        dimensions {
          clientRequestHTTPHost
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_hostnames" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "$TOP_N")") || {
    log_warn "collect_hostnames skipped"
    return 0
  }

  if ! graphql_check_errors "collect_hostnames" warn "$response"; then
    return 0
  fi

  while IFS=$'\t' read -r hostname requests bandwidth visits; do
    [[ -z "${hostname:-}" ]] && continue
    write_point "cloudflare_analytics_hostname" \
      "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),hostname=$(escape_tag_value "$hostname")" \
      "requests=${requests}i,bandwidth=${bandwidth},visits=${visits}i" \
      "$(day_timestamp "$day")"
  done < <(read_top_groups "$response" "clientRequestHTTPHost")
}

collect_paths() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response query

  if ! is_enabled "$ENABLE_TOP_PATHS"; then
    return 0
  fi

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequestsAdaptiveGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
        orderBy: [count_DESC]
      ) {
        count
        sum {
          edgeResponseBytes
          visits
        }
        dimensions {
          clientRequestPath
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_paths" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "$TOP_N")") || {
    log_warn "collect_paths skipped"
    return 0
  }

  if ! graphql_check_errors "collect_paths" warn "$response"; then
    return 0
  fi

  while IFS=$'\t' read -r path requests bandwidth visits; do
    [[ -z "${path:-}" ]] && continue
    write_point "cloudflare_analytics_path" \
      "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),path=$(escape_tag_value "$path")" \
      "requests=${requests}i,bandwidth=${bandwidth},visits=${visits}i" \
      "$(day_timestamp "$day")"
  done < <(read_top_groups "$response" "clientRequestPath")
}

collect_user_agents() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response query

  if ! is_enabled "$ENABLE_USER_AGENTS"; then
    return 0
  fi

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequestsAdaptiveGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
        orderBy: [count_DESC]
      ) {
        count
        sum {
          edgeResponseBytes
          visits
        }
        dimensions {
          userAgent
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_user_agents" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "$TOP_N")") || {
    log_warn "collect_user_agents skipped"
    return 0
  }

  if ! graphql_check_errors "collect_user_agents" warn "$response"; then
    return 0
  fi

  while IFS=$'\t' read -r user_agent requests bandwidth visits; do
    [[ -z "${user_agent:-}" ]] && continue
    write_point "cloudflare_analytics_user_agent" \
      "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),user_agent=$(escape_tag_value "$user_agent")" \
      "requests=${requests}i,bandwidth=${bandwidth},visits=${visits}i" \
      "$(day_timestamp "$day")"
  done < <(read_top_groups "$response" "userAgent")
}

collect_content_types() {
  local day="$1"
  local start="$2"
  local end="$3"
  local zone_tag response timestamp query

  if ! is_enabled "$ENABLE_CONTENT_TYPES"; then
    return 0
  fi

  zone_tag=$(escape_tag_value "$CLOUDFLARE_ZONE_TAG")
  timestamp=$(day_timestamp "$day")

  read -r -d '' query <<'EOF' || true
query($zoneTag: String!, $start: Time!, $end: Time!, $limit: Int!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      series: httpRequests1mGroups(
        filter: {
          datetime_geq: $start
          datetime_lt: $end
          requestSource: "eyeball"
        }
        limit: $limit
      ) {
        sum {
          contentTypeMap {
            edgeResponseContentTypeName
            requests
            bytes
          }
        }
      }
    }
  }
}
EOF

  response=$(graphql_query "collect_content_types" "$query" "$(build_query "$query" "$CLOUDFLARE_ZONE_TAG" "$start" "$end" "5000")") || {
    log_warn "collect_content_types skipped"
    return 0
  }

  if ! graphql_check_errors "collect_content_types" warn "$response"; then
    return 0
  fi

  while IFS=$'\t' read -r content_type requests bytes; do
    [[ -z "${content_type:-}" ]] && continue
    write_point "cloudflare_analytics_content_type" \
      "zone=${zone_tag},cfZone=${zone_tag},date=$(escape_tag_value "$day"),content_type=$(escape_tag_value "$content_type")" \
      "requests=${requests}i,bandwidth=${bytes}" \
      "$timestamp"
  done < <(read_content_type_rows "$response")
}

collect_day() {
  local day="$1"
  local bounds start end

  bounds=$(day_bounds "$day")
  IFS=$'\t' read -r start end <<<"$bounds"

  log_info "Collecting ${day}"
  collect_totals "$day" "$start" "$end"
  collect_countries "$day" "$start" "$end"
  collect_cache "$day" "$start" "$end"
  collect_status_codes "$day" "$start" "$end"
  collect_threats "$day" "$start" "$end"
  collect_hostnames "$day" "$start" "$end"
  collect_paths "$day" "$start" "$end"
  collect_user_agents "$day" "$start" "$end"
  collect_content_types "$day" "$start" "$end"
}

main() {
  local i day
  validate_config
  log_info "Running: ${SCRIPT_PATH}"

  for ((i=0; i<DAYS; i++)); do
    day=$(date -u -d "-${i} day" +'%Y-%m-%d')
    collect_day "$day"
  done

  log_info "Done."
}

main "$@"
