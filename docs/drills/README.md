# Drills

Each drill breaks something on purpose, checks that the alerting and the
automation behave as designed, and ends with a short write-up.

| # | Drill | Where | Proves |
|---|---|---|---|
| 01 | [Unsafe migration](01-unsafe-migration.md) | local + AWS | expand/contract, CI migration guard, 5xx alerting |
| 02 | [Point-in-time restore](02-point-in-time-restore.md) | AWS | backups actually restore; measured RTO/RPO |
| 03 | [Multi-AZ failover](03-multi-az-failover.md) | AWS | HA config; app reconnects; measured error window |
| 04 | [Bad release](04-bad-release.md) | local + AWS | start-up check + ECS circuit breaker rollback |
| 05 | [Connection-pool exhaustion](05-connection-pool-exhaustion.md) | local | capacity limits are visible and alerted |

**Write-up rule:** the "Observed" section of each drill is filled in only with
what actually happened when the drill was run (timestamps, screenshots in
`results/`, numbers from the scripts). Never with the expected result.
