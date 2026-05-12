# Flux Debug Queries

Use these queries in Grafana Explore with the InfluxDB v2 datasource.

Replace the bucket value if needed.

```flux
import "influxdata/influxdb/schema"

schema.measurements(bucket: "laurentkeller.org")
```

```flux
import "influxdata/influxdb/schema"

schema.fieldKeys(
  bucket: "laurentkeller.org",
  predicate: (r) => r._measurement == "cloudflare_analytics"
)
```

```flux
import "influxdata/influxdb/schema"

schema.fieldKeys(
  bucket: "laurentkeller.org",
  predicate: (r) => r._measurement == "cloudflare_analytics_country"
)
```

```flux
import "influxdata/influxdb/schema"

schema.tagKeys(
  bucket: "laurentkeller.org",
  predicate: (r) => r._measurement == "cloudflare_analytics_country"
)
```

```flux
import "influxdata/influxdb/schema"

schema.tagValues(
  bucket: "laurentkeller.org",
  tag: "zone",
  predicate: (r) => r._measurement == "cloudflare_analytics"
)
```

```flux
from(bucket: "laurentkeller.org")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement =~ /^cloudflare_analytics/)
  |> keep(columns: ["_time", "_measurement", "_field", "_value", "zone", "country", "status", "cache_status", "hostname", "path"])
  |> limit(n: 100)
```
