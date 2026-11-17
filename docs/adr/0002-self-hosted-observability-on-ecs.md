# ADR 0002: Self-hosted Prometheus, Loki, Grafana and Alertmanager on ECS

**Status:** accepted · **Date:** 2026-11

## Context
We need metrics, logs, dashboards and alerting with runbook links. Options:

1. CloudWatch only (metrics, Logs Insights, alarms)
2. Amazon Managed Prometheus + Amazon Managed Grafana
3. Self-hosted Prometheus / Loki / Grafana / Alertmanager on ECS

## Decision
Option 3 for application telemetry, **plus** CloudWatch alarms for the
infrastructure signals that must work even if option 3 is down (ALB 5xx,
unhealthy targets, RDS CPU/storage/connections, budget).

## Why
- The same configuration runs locally in docker compose and in AWS, so
  dashboards and alert rules are developed and tested on a laptop
  (`promtool test rules` in CI).
- PromQL alerts on application metrics (5xx ratio, p95 latency, DB pool
  saturation, DB reachability) are more precise than CloudWatch metric math.
- Cost: four small tasks on Fargate Spot cost less than AMP + AMG at this scale.

## Trade-offs accepted
- **Prometheus storage is ephemeral** (container disk, 3-day retention). A Spot
  interruption or redeploy loses metric history. Production fix: EFS volume or
  `remote_write` to Amazon Managed Prometheus.
- **Single instance of each component.** No HA for Alertmanager. That's
  acceptable because the CloudWatch alarms send critical infrastructure alerts
  independently.
- **Fargate Spot** can interrupt with two minutes' notice. Fine for
  observability, not used for the API.
- **Logs go to Loki and CloudWatch** (FireLens with two outputs), so logs are
  never lost if Loki is down. The cost is double ingestion; CloudWatch
  retention is short (14 days) to compensate.
- **No public UI.** Grafana/Prometheus are reached through ECS Exec port
  forwarding (`scripts/port-forward.sh`). Safer, but less convenient than an
  SSO-protected ALB rule.
