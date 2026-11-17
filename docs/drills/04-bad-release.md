# Drill 04: a release that cannot reach the database

## Scenario
A release ships with a broken DB setting (wrong database name / secret).

## Design under test
- The app checks the DB at start-up and exits if it is unreachable (`wait_for_database` in `main.py`).
- ECS: new tasks keep failing -> **deployment circuit breaker** stops the
  rollout and **rolls back** to the previous task definition. The old tasks kept
  serving the whole time (`minimum_healthy_percent = 100`).
- `terraform apply` waits for steady state, so the pipeline goes red.

## Run it locally
```bash
make up && make seed
make drill-04-break   # api container exits; ApiTargetDown fires after ~2 min
make drill-04-fix
```

## Run it in AWS
On a branch, set a wrong `DB_NAME` for the API in `terraform/envs/staging/main.tf`
(e.g. `merge(local.db_environment, { DB_NAME = "nope", ... })`) and deploy it
with `workflow_dispatch`. Watch:
```bash
aws ecs describe-services --cluster referrals-staging --services referrals-staging-api \
  --query 'services[0].{deployments:deployments[*].[status,rolloutState,taskDefinition],events:events[:8].message}'
```
Expected: rolloutState FAILED, then the circuit-breaker event, then the old task definition PRIMARY again.
Meanwhile, `curl <alb>/healthz` keeps answering with the previous version.

## Observed: local run, 2026-11-17 (docker compose)

| Time (CET) | Event |
|---|---|
| 19:13:22 | `make drill-04-break`: API restarted with `DATABASE_URL` pointing at a database that does not exist |
| ~19:13:52 | Start-up check gives up after its 30 s retry window: `FATAL: database "does_not_exist" does not exist` -> `Application startup failed. Exiting.`, container **Exited (3)** |
| 19:14–19:16 | Prometheus target `referrals-api` **DOWN** (`lookup api ... no such host`); ApiTargetDown Pending |
| 19:16:13 | **`[FIRING] ApiTargetDown`** received by alert-sink |
| ~19:25 | `make drill-04-fix`; API back, `/readyz` -> `ready`, schema `0002` |
| ~19:26 | `[RESOLVED] ApiTargetDown` (about 1 min after the API was back) |

Screenshots: `results/drill-04-2-target-down.png`, `results/drill-04-3-alert-firing.png`.

### Findings
1. **The release failed fast and loudly.** It never started serving with a wrong
   config: one clear log line naming the cause, then a non-zero exit (uvicorn
   uses exit code 3 for a failed start-up). That's what makes an orchestrator's
   rollback possible. A release that starts "healthy" and fails on first request
   would not be rolled back.
2. **Detection: ~2 min 50 s** from the bad release to the alert (30 s start-up retry
   + 2 min `for:` + scrape/evaluation interval + 30 s Alertmanager `group_wait`).
3. **Locally there's no safety net, and that's the point of comparison.** Docker
   compose replaced the working container with the broken one, so the API was
   fully down until the manual fix (~12 min). On ECS the same failure is contained:
   `minimum_healthy_percent = 100` keeps the old tasks serving, the new tasks exit,
   the deployment circuit breaker marks the rollout FAILED and rolls back, and
   `terraform apply` (`wait_for_steady_state`) turns the pipeline red. That part
   needs the AWS run (see "Run it in AWS" above).
4. **`ApiNoTargets` did not fire, correctly.** Locally the scrape target is static
   (`api:8000`), so the target still exists and is just DOWN. In AWS, with Cloud Map
   discovery, a service with zero healthy tasks has no DNS records, and
   `ApiNoTargets` is the alert that catches it.

### What I would change
- Lower `ApiTargetDown`'s `for:` to 1 min for a single-service stack, or page on
  the ECS "deployment failed" event (EventBridge -> SNS) so a failed rollout pages
  immediately instead of after the alert window.
