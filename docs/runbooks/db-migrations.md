# Runbook: database migrations

## The rule
During an ECS rolling deployment the **old and new release run at the same
time against the same database** for a few minutes. If the deployment fails,
the circuit breaker rolls back to the old release, which then runs against the
**new** schema. So every migration must work with **both** releases.

## Expand / contract
A breaking change (rename, drop, type change, new NOT NULL) is split over releases:

| Release | Migration | App code |
|---|---|---|
| N (expand) | add the new column (nullable), backfill in batches | writes old + new, reads new |
| N+1 (contract) | drop the old column | writes/reads new only |

Example in this repo: `title` -> `display_name`.
`0002_expand_add_display_name.py` is release N. `migrations/pending/0004_contract_drop_title.py`
is release N+1. It stays out of `versions/` until no task reads `title` any more.

## Guard rails in the pipeline
- `scripts/check_migrations.py` fails CI on drop/rename/type change/SET NOT NULL/
  non-concurrent index on an existing table, unless the line has a
  `# contract-approved: <reason>` comment (so the exception is visible in review).
- Migrations run with `lock_timeout = 5s` and `statement_timeout = 60s`
  (`migrations/env.py`), so a migration waiting on a lock fails fast instead of
  queueing every API query behind it.
- The migration runs as a one-off ECS task **before** `terraform apply`. If it
  fails, the pipeline stops and the service is not touched.
- CI runs upgrade -> downgrade -> upgrade against a real Postgres.

## The migration step failed in the pipeline
1. Read the task logs printed by the job (or `/ecs/referrals-staging-migrate` in CloudWatch).
2. `lock timeout` -> something held a lock: check `pg_stat_activity` for long
   transactions (`scripts/run-oneoff.sh python -c "..."`), then re-run the job.
3. A real error -> the migration is transactional and rolled back; the old
   release is still serving. Fix forward in a new PR.
4. Never edit a migration that already ran in any environment. Add a new one.

## A bad migration reached the database
1. Is the API failing? Check Grafana (5xx ratio) and the `ApiHigh5xxRate` alert.
2. If the migration is reversible and the old code needs the old schema:
   `scripts/run-oneoff.sh alembic downgrade <previous-revision>`.
3. If data was destroyed: point-in-time restore (see `dr-restore.md`).
4. Write it up (template: `docs/drills/01-unsafe-migration.md`).
