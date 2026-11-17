# Drill 03: Multi-AZ failover under traffic

## Scenario
The primary DB instance (or its AZ) fails.

## Hypothesis
- RDS fails over to the standby in under 2 minutes; the endpoint DNS name stays the same.
- The API returns errors only during the failover window. `pool_pre_ping`
  discards dead connections, so there's no manual restart.
- `ApiDatabaseUnreachable` may fire briefly and then resolve.

## Run it (AWS, `db_multi_az = true`)
```bash
scripts/loadtest.py --base-url "$(terraform -chdir=terraform/envs/staging output -raw api_base_url)" --duration 400 &
scripts/rds-failover-drill.sh
```
Report: `results/rds-failover-<date>.md` (AZ before/after, error window).

## Things to look at afterwards
- Did any API task need replacing, or did all of them recover by themselves?
- Error window vs RDS "failover completed" event time: is the app slower to
  recover than the DB? If so: lower `DB_CONNECT_TIMEOUT`, check DNS TTL caching.

## Observed (fill in after running)
- Date:
- AZ before / after:
- Error window (from the report):
- Alerts fired / resolved:
- What I would change:
