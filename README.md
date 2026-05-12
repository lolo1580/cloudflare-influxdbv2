# Cloudflare Analytics to InfluxDB v2

This script pulls Cloudflare analytics through the GraphQL API and writes the results to an InfluxDB v2 bucket. It keeps the existing measurements intact and adds separate measurements for cache, status codes, threats, hostnames, paths, user agents, and content types.

## Requirements

1. InfluxDB v2 reachable from the host that runs the script.
2. A Cloudflare API token with read access to the zone analytics GraphQL API, or a legacy global key + email.
3. `bash`, `curl`, `jq`, GNU `date`, and `sed`.

## Configuration

Create a local `.env` file next to `cloudflare-analytics.sh`:

```bash
cp .env.example .env
```

Then edit `.env`:

```bash
InfluxDBURL="http://YOUR_INFLUXDB_IP"
InfluxDBPort="8086"
InfluxDBBucket="cloudflare"
InfluxDBOrg="YourOrgName"
InfluxDBToken="your_influxdb_token"

CLOUDFLARE_API_TOKEN="your_cloudflare_api_token"
CLOUDFLARE_ZONE_TAG="your_zone_id"
CLOUDFLARE_GLOBAL_API_KEY=""
CLOUDFLARE_EMAIL="your_cloudflare_email"

DAYS=1
TOP_N=20
ENABLE_CACHE_METRICS=true
ENABLE_STATUS_METRICS=true
ENABLE_THREAT_METRICS=true
ENABLE_TOP_PATHS=true
ENABLE_USER_AGENTS=false
ENABLE_CONTENT_TYPES=true
```

The `.env` file is ignored by Git so tokens and local settings are not published. The script loads `${SCRIPT_DIR}/.env` by default. To use another file, set `ENV_FILE`:

```bash
ENV_FILE=/etc/cloudflare-analytics/laurentkeller.org.env ./cloudflare-analytics.sh
```

`zone` and `date` are written as tags on every measurement. `cfZone` is also kept for backwards compatibility with the previous setup.

## What The Script Collects

The script uses several independent GraphQL queries so one metric family can fail without stopping the others.

`collect_totals()`:
- `cfRequestsAll`
- `cfBandwidthAll`
- `cfVisits`

`collect_countries()`:
- `requests`
- `bandwidth`
- `visits`
- tag `country`

`collect_cache()`:
- `requests`
- `bandwidth`
- tag `cache_status=hit|miss`

`collect_status_codes()`:
- `requests`
- tag `status`

`collect_threats()`:
- `threats`

`collect_hostnames()`:
- `requests`
- `bandwidth`
- `visits`
- tag `hostname`

`collect_paths()`:
- `requests`
- `bandwidth`
- `visits`
- tag `path`

`collect_user_agents()`:
- `requests`
- `bandwidth`
- `visits`
- tag `user_agent`

`collect_content_types()`:
- `requests`
- `bandwidth`
- tag `content_type`

## Measurements

### `cloudflare_analytics`
Tags: `zone`, `cfZone`, `date`

Fields:
- `cfRequestsAll`
- `cfBandwidthAll`
- `cfVisits`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics" and r.zone == "YOUR_ZONE_ID")
  |> keep(columns: ["_time", "_field", "_value", "zone", "date"])
```

### `cloudflare_analytics_country`
Tags: `zone`, `cfZone`, `date`, `country`

Fields:
- `requests`
- `bandwidth`
- `visits`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_country" and r.country == "US")
```

### `cloudflare_analytics_cache`
Tags: `zone`, `cfZone`, `date`, `cache_status`

Fields:
- `requests`
- `bandwidth`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_cache")
  |> pivot(rowKey: ["_time", "cache_status"], columnKey: ["_field"], valueColumn: "_value")
```

### `cloudflare_analytics_status`
Tags: `zone`, `cfZone`, `date`, `status`

Fields:
- `requests`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_status")
  |> group(columns: ["status"])
```

### `cloudflare_analytics_threats`
Tags: `zone`, `cfZone`, `date`

Fields:
- `threats`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_threats")
```

### `cloudflare_analytics_hostname`
Tags: `zone`, `cfZone`, `date`, `hostname`

Fields:
- `requests`
- `bandwidth`
- `visits`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_hostname")
  |> top(n: 20, columns: ["requests"])
```

### `cloudflare_analytics_path`
Tags: `zone`, `cfZone`, `date`, `path`

Fields:
- `requests`
- `bandwidth`
- `visits`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_path")
```

### `cloudflare_analytics_user_agent`
Tags: `zone`, `cfZone`, `date`, `user_agent`

Fields:
- `requests`
- `bandwidth`
- `visits`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_user_agent")
```

### `cloudflare_analytics_content_type`
Tags: `zone`, `cfZone`, `date`, `content_type`

Fields:
- `requests`
- `bandwidth`

Flux:

```flux
from(bucket: "cloudflare")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "cloudflare_analytics_content_type")
```

## Plan-Dependent Metrics

Cloudflare says the essential HTTP analytics datasets are available on all plans, but retention and query windows differ by plan. Some fields are not available everywhere, and some collections may still fail on specific zones or plan combinations.

The script handles this by:
- failing fast on the primary totals query;
- logging warnings for secondary collectors;
- continuing with the remaining collectors when a secondary query fails;
- logging the exact GraphQL error returned by Cloudflare.

Bot score / bot class metrics are not collected by default here because Cloudflare documents bot analytics separately from the essential HTTP analytics dataset, and those fields are not guaranteed on a Free zone.

## Grafana Dashboard

An importable Grafana 10+ dashboard is available at:

```text
dashboard/cloudflare-analytics-dashboard.json
```

It is built only from measurements written by `cloudflare-analytics.sh`:
- `cloudflare_analytics`
- `cloudflare_analytics_country`
- `cloudflare_analytics_hostname`
- `cloudflare_analytics_path`
- `cloudflare_analytics_cache` when present
- `cloudflare_analytics_status` when present

The dashboard does not use unsupported measurements such as threats, user agents, or content types by default. Cache and status sections use hidden Grafana variables based on `schema.measurements()` so their panels repeat only when the corresponding measurement exists in the selected bucket.

Import steps:

1. In Grafana, open `Dashboards` -> `New` -> `Import`.
2. Upload `dashboard/cloudflare-analytics-dashboard.json`.
3. Select your InfluxDB v2 datasource when Grafana asks for `DS_INFLUXDB`.
4. Set the `bucket` variable to your bucket name, for example `cloudflare`.
5. Select `zone` or leave it on `All`.

Dashboard sections:
- Overview: total requests, bandwidth, visits, top country, top hostname, top path.
- Traffic: requests, bandwidth, and visits over time.
- Countries: request geomap plus a top countries table.
- Hostnames: top hostnames table and top 5 hostnames over time.
- Paths: top paths table and top 10 paths bar chart.
- Status Codes: HTTP status distribution, timeline, and 4xx/5xx stat when `cloudflare_analytics_status` exists.
- Cache: HIT/MISS ratio, cached vs uncached bandwidth, and cache efficiency when `cloudflare_analytics_cache` exists.

Screenshot placeholders:

```markdown
![Cloudflare dashboard overview](docs/screenshots/grafana-overview.png)
![Cloudflare countries geomap](docs/screenshots/grafana-countries.png)
![Cloudflare cache and status](docs/screenshots/grafana-cache-status.png)
```

## Systemd

Use a oneshot service plus a timer. Cloudflare daily analytics can lag by several
hours, so the recommended schedule is once per day after the data has settled.

```ini
[Unit]
Description=Cloudflare Analytics to InfluxDB
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME/gh/cloudflare-influxdbv2
Environment=ENV_FILE=/home/YOUR_USERNAME/gh/cloudflare-influxdbv2/.env
ExecStart=/home/YOUR_USERNAME/gh/cloudflare-influxdbv2/cloudflare-analytics.sh
```

```ini
[Unit]
Description=Run Cloudflare Analytics to InfluxDB daily

[Timer]
OnCalendar=*-*-* 04:30:00
AccuracySec=15min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable cloudflare-analytics.timer
sudo systemctl start cloudflare-analytics.timer
```

## Validation

```bash
shellcheck cloudflare-analytics.sh
bash -n cloudflare-analytics.sh
./cloudflare-analytics.sh
```

If the script is still configured with placeholders, it will exit early with a configuration error before making any Cloudflare request.
