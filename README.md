# Cloudflare Analytics to InfluxDB v2

This script collects Cloudflare metrics using the GraphQL API and pushes them to an InfluxDB v2 bucket. It is designed to feed a Grafana dashboard with the following metrics:

- Daily totals: `cfRequestsAll`, `cfBandwidthAll`, `cfVisits`
- Per-country daily metrics: `requests`, `bandwidth`, `visits`
- Tags: `cfZone`, and `country` on per-country points

## Prerequisites

1. **InfluxDB v2** installed and reachable (URL, port, organization, bucket, token).
2. **Cloudflare**: an API token with read permissions for the GraphQL API on the desired zone.
3. **Tools** on the machine where the script will run:
   - `bash` (version 4+)
   - `curl` (for HTTP requests)
   - `jq` (for JSON parsing)
   - GNU `date` and `seq` (usually provided by coreutils on Linux)
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

CLOUDFLARE_API_TOKEN="your_cloudflare_api_token"
CLOUDFLARE_ZONE_TAG="your_cloudflare_zone_id"

# Optional fallback if you do not use an API token:
CLOUDFLARE_GLOBAL_API_KEY=""
CLOUDFLARE_EMAIL="your_cloudflare_email"
```

The recommended Cloudflare authentication method is a dedicated API token with `Zone:Analytics:Read` on the target zone. The script exits early if required values are empty or still set to placeholders.

## Script Workflow

1. Defines the last `DAYS` calendar days as the time range.
2. Sends a GraphQL request to Cloudflare to retrieve:
   - Daily totals derived from `httpRequestsAdaptiveGroups`
   - Per-country request, bandwidth, and visit totals
3. Parses and transforms data into InfluxDB Line Protocol.
4. Pushes each metric and country-specific data to InfluxDB.
5. Fails with a non-zero exit code if Cloudflare returns GraphQL errors or InfluxDB rejects a write.

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
- Use measurement `cloudflare_analytics` for daily totals
- Use fields `cfRequestsAll`, `cfBandwidthAll`, `cfVisits`
- For per-country stats, use measurement `cloudflare_analytics_country`, tag `country`, and fields `requests`, `bandwidth`, `visits`

## Grafana Dashboard

Import or build a dashboard that matches the measurement names and fields written by this script.
- Data source: InfluxDB v2 with `http://<host>:8086`, org, bucket, token.
- Variable `zone`: value is your `zone_id`
- Recommended time range: last 7 days or 24 hours

## Customization

- Adjust `DAYS` to collect a longer or shorter range
- Extend GraphQL query for more fields (HTTP status, browsers)
- Change timer interval via `OnUnitActiveSec` in the `.timer` file
