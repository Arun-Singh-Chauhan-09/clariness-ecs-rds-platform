# Drill 01: an unsafe migration during a rolling deploy

## Scenario
A developer "just renames" `studies.title` to `studies.name`
(`drills/unsafe_9001_rename_title.py`). The release that is still running
inserts into `title`.

## Hypothesis
1. CI blocks the migration (`check_migrations.py`, rule `rename_column`).
2. If it is forced through, `POST /studies` returns 500 for the old release,
   and `ApiHigh5xxRate` fires within ~5 minutes.
3. The expand/contract version (`0002` + `pending/0003`) causes no errors.

## Run it locally
```bash
make up && make seed
make drill-01-break        # guard prints the finding; migration is forced anyway
python3 scripts/loadtest.py --duration 480 --study-writes 0.2   # 20% of requests create studies (the broken path)
make logs                  # alert-sink shows ApiHigh5xxRate FIRING
make drill-01-fix          # downgrade to 0002, remove the bad file
```
Watch: Grafana -> Referrals API -> "5xx ratio" and the logs panel.

## In AWS
Open a PR containing the bad migration: the `ci` workflow must fail at
"Block unsafe migrations". That failed check is the evidence.

## Fix
Expand/contract (see `docs/runbooks/db-migrations.md`) and the CI guard.

## Observed: local run, 2026-11-17 (docker compose)

_At the time of this run the unsafe migration was revision `0003`. It is now `9001`, because `0003` became the least-privilege database role migration; the drill works the same way._

| Time (CET) | Event |
|---|---|
| 18:57 | `make drill-01-break`: guard flags `0003_rename_title.py:22 [rename_column]`; migration forced anyway (`0002 -> 0003`) |
| ~19:00 | Load starts: 20 workers, 20% of requests create studies (`--study-writes 0.2`) |
| 19:01 | Grafana "5xx ratio" red at 8.5% and climbing (5-minute rate window filling up) |
| 19:05 | Logs panel: `POST /studies 500`, `Exception in ASGI application`, SQLAlchemy `ProgrammingError` (column `title` missing) |
| 19:06:13 | **ApiHigh5xxRate FIRING**: alert-sink receives `[FIRING] ApiHigh5xxRate` through Alertmanager |
| 19:09 | `make drill-01-fix`: `downgrade 0003 -> 0002`, bad file removed |
| 19:14:13 | `[RESOLVED] ApiHigh5xxRate` (about 5 min after the fix: the 5-minute rate window drains, plus Alertmanager's group interval) |

**Load-test result (8 min):** 89,151 requests at 185.7 rps.
`500`: 17,879 (**20.05%**, exactly the share of study writes). `200`: 56,914. `201`: 14,358.
Latency p50 103 ms, p95 154 ms, p99 195 ms. Reads and referral writes were unaffected.

Screenshots: `results/drill-01-1-grafana-5xx.png`, `drill-01-2-logs.png`,
`drill-01-3-alert-firing.png`, `drill-01-4-alert-sink.png`.

### Findings
1. **Partial outage, invisible to health checks.** `/healthz`, `/readyz`, p95 latency
   and task count all stayed green. Only one endpoint failed. The 5xx-ratio alert
   caught it; an uptime check would not have.
2. **Detection took ~6 min** (first errors ~19:00 -> FIRING 19:06:13): the 5-minute
   rate window has to fill past 5%, then `for: 5m`, then Alertmanager `group_wait: 30s`.
   Fine for a staging signal, slow for a broken write path.
3. **The first attempt of this drill proved nothing.** The default load only
   wrote referrals, never studies, so every request was 2xx even though the schema
   was broken. A drill (or a smoke test, or a canary) only tests the code paths
   its traffic actually hits. Fixed by adding `--study-writes`.
4. **The deploy pipeline would have caught it before the alert:** `scripts/smoke-test.sh`
   does a `POST /studies` right after `terraform apply`, so in AWS the deployment would
   go red within seconds of rollout. And the CI guard blocks the migration before merge.

### What I would change
- Add a per-route rule for write endpoints (`route=~"POST .*"` 5xx > 1% `for: 2m`)
  so a broken write path pages in ~3 min instead of ~6.
- Keep the smoke test exercising one write per core entity (studies, referrals).
