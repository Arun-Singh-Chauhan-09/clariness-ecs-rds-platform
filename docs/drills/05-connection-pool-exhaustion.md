# Drill 05: connection-pool exhaustion

## Scenario
Traffic grows faster than the DB connection pool (`DB_POOL_SIZE=2`, 40 concurrent clients).

## Hypothesis
- Requests queue for a connection, so p95 latency rises; requests waiting longer than
  `DB_POOL_TIMEOUT` (5 s) fail with 500.
- `DbPoolSaturated` fires (pool at least 90% used for 5 min), then `ApiHighLatencyP95` and possibly `ApiHigh5xxRate`.
- The dashboard shows *why*: pool usage pinned at its size.

## Run it locally
```bash
make up && make seed
make drill-05        # pool=2, 40 workers for 7 minutes, then pool back to 5
```

## The capacity rule this drill teaches
`api_max_tasks x DB_POOL_SIZE + 1 migration task <= max_connections - headroom`.
db.t4g.micro allows ~80 connections. 4 tasks x 5 = 20 is fine. Scaling to 20 tasks
is not, which calls for RDS Proxy or a bigger instance.

## Observed (fill in after running)
- Date:
- p95 before / during:
- 5xx during:
- Alerts fired (order and times):
- What I would change:
