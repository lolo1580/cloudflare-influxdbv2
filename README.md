# Cloudflare Analytics to InfluxDB v2

This script collects Cloudflare metrics using the GraphQL API and pushes them to an InfluxDB v2 bucket. It is designed to feed a Grafana dashboard (e.g., Jorge de la Cruz’s dashboard) with the following metrics:

- Bandwidth (`bytes`, `cached_bytes`)
- Number of requests (`requests`, `cached_requests`)
- Number of threats (`threats`)
- Page views (`pageviews`)
- Unique visitors (`uniques`)
- Request distribution by country (`country_requests`)

## Prerequisites

1. **InfluxDB v2** installed and reachable (URL, port, organization, bucket, token).
2. **Cloudflare**: an API token with read permissions for the GraphQL API on the desired zone.
3. **Tools** on the machine where the script will run:
   - `bash` (version 4+)
   - `curl` (for HTTP requests)
   - `jq` (for JSON parsing)
   - Network access to `api.cloudflare.com` and the InfluxDB instance

## Installation

```bash
mkdir -p ~/script/cloudflare
cd ~/script/cloudflare
# Copy cloudflare-analytics.sh here
chmod +x cloudflare-analytics.sh
```

Install dependencies:

```bash
sudo apt update
sudo apt install -y curl jq
```

## Configuration

Edit the variables at the top of the script to match your environment:

```bash
InfluxDBURL="http://YOUR_INFLUXDB_IP"
InfluxDBPort="8086"
InfluxDBBucket="cloudflare"
InfluxDBOrg="YourOrgName"
InfluxDBToken="your_influxdb_token"

cloudflareapikey="your_cloudflare_token"
cloudflarezone="your_cloudflare_zone_id"
cloudflareemail="your_cloudflare_email"
```

## Script Workflow

1. Defines the last 24 hours as the time range.
2. Sends a GraphQL request to Cloudflare to retrieve:
   - Daily metrics: `bytes`, `cachedBytes`, `requests`, `cachedRequests`, `threats`, `pageViews`, and `countryMap`
   - Unique visitors (`uniques`)
3. Parses and transforms data into InfluxDB Line Protocol.
4. Pushes each metric and country-specific data to InfluxDB.
5. Sends a test point for debugging.

## Manual Execution

```bash
cd ~/script/cloudflare
./cloudflare-analytics.sh
```

## Automating with systemd (Optional)

Create a service file at `/etc/systemd/system/cloudflare-analytics.service`:

```ini
[Unit]
Description=Cloudflare Analytics to InfluxDB
After=network.target

[Service]
Type=oneshot
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME/script/cloudflare
ExecStart=/home/YOUR_USERNAME/script/cloudflare/cloudflare-analytics.sh
```

Create a timer at `/etc/systemd/system/cloudflare-analytics.timer`:

```ini
[Unit]
Description=Run cloudflare-analytics.service every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable cloudflare-analytics.timer
sudo systemctl start cloudflare-analytics.timer
```

## Verify in InfluxDB

### CLI:

```bash
influx query 'from(bucket: "cloudflare") |> range(start: -7d) |> limit(n: 10)' \
  --org YourOrgName \
  --host http://YOUR_INFLUXDB_IP:8086 \
  --token "your_token"
```

### UI:

Use the InfluxDB Data Explorer:
- Select the `cloudflare` bucket
- Pick the last 7 days as time range
- Use measurement `cloudflare`, fields (e.g., bytes, requests)
- For per-country stats, use the tag `country` and field `country_requests`

## Grafana Dashboard

Import Jorge de la Cruz’s dashboard or your custom one.
- Data source: InfluxDB v2 with `http://<host>:8086`, org, bucket, token.
- Variable `zone`: value is your `zone_id`
- Recommended time range: last 7 days or 24 hours

## Customization

- Adjust `back_seconds` to collect a longer range
- Extend GraphQL query for more fields (HTTP status, browsers)
- Change timer interval via `OnUnitActiveSec` in the `.timer` file
