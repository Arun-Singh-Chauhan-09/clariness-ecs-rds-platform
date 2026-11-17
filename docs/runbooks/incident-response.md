# Runbook: alerts

Alerts come from two independent paths, so one failing doesn't blind us:
- **Alertmanager** (Prometheus rules, application signals) -> SNS
- **CloudWatch alarms** (ALB, RDS, budget) -> the same SNS topic

First steps for any alert: Grafana dashboard **Referrals API**
(`scripts/port-forward.sh grafana`), then the recent deploys (GitHub Actions
`deploy` runs), then the logs panel / CloudWatch `/ecs/referrals-staging-api/app`.

## ApiTargetDown
Prometheus can't scrape an API task.
1. `aws ecs describe-services --cluster referrals-staging --services referrals-staging-api` -> events, deployments.
2. If a deployment is in progress and tasks are crash-looping, the circuit
   breaker will roll back. Check the stopped tasks' `stoppedReason`.
3. If no deployment: check whether the task was replaced (CPU/memory), and
   check the security group rule `Prometheus scrape` on the API SG.

## ApiNoTargets
No API task is registered in Cloud Map at all. Is the service at 0 tasks?
`aws ecs update-service --desired-count 2` while you investigate.

## ApiHigh5xxRate
1. Did it start right after a deploy? Compare with the `deploy` workflow time.
   If yes: revert the commit (the pipeline redeploys the previous SHA), or
   for a faster rollback `aws ecs update-service --task-definition <previous revision>`.
2. Logs panel: filter `status=5`. Look at the routes: one route or all?
3. All routes + DB errors: go to **ApiDatabaseUnreachable**.

## ApiHighLatencyP95
1. Is the DB pool saturated (dashboard: DB pool usage)? -> **DbPoolSaturated**.
2. RDS slow query log (`log_min_duration_statement = 500ms`) in CloudWatch Logs.
3. CPU of the service: autoscaling should add tasks (max 4). Hitting max? Raise `api_max_tasks`.

## ApiDatabaseUnreachable
1. RDS events: `aws rds describe-events --source-identifier referrals-staging --duration 60`.
   A Multi-AZ failover shows as "Multi-AZ instance failover started/completed":
   expect 1-2 minutes; `pool_pre_ping` reconnects automatically afterwards.
2. Security group change? The daily drift check would flag it; check CloudTrail now.
3. Secret rotated? RDS rotates the master password; running tasks keep their
   connections, new tasks read the new secret. Force a fresh deployment if old
   tasks fail to reconnect: `aws ecs update-service --force-new-deployment`.

## DbPoolSaturated
Each task has `DB_POOL_SIZE` connections; requests queue when all are in use.
1. Short spike under load: autoscaling adds tasks.
2. Sustained: slow queries are holding connections -> check the slow query log.
3. Raising the pool: keep `api_max_tasks x DB_POOL_SIZE + migration task`
   below the instance's `max_connections` (the RDS connections alarm is set at 60).

## LokiDown
App logs still go to CloudWatch (FireLens writes to both). Check the Loki task
(Spot interruption?) and redeploy it: `aws ecs update-service --force-new-deployment
--service referrals-staging-loki`.
