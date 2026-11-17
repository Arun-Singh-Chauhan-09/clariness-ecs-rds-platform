# Runbook: restore the database

## What protects the data
| Layer | Covers | Recovery point |
|---|---|---|
| Multi-AZ standby | AZ / instance failure | 0 (synchronous), automatic failover ~1-2 min |
| Automated backups + transaction logs (7 days) | bad migration, accidental delete, corruption | any second in the window, typically up to ~5 min behind |
| Cross-region backup replication (`dr_region`) | loss of the primary region | same, restored in the DR region |

Targets for this service (staging): **RPO <= 5 min, RTO <= 30 min**. They are
measured, not assumed: see `docs/drills/results/`.

## Restore to a point in time (e.g. before a bad delete)
PITR always creates a **new** instance; the original is not touched.

1. Find the time just before the incident (UTC), from logs or the deploy history.
2. Rehearse first, or restore for real, with the drill script (it restores,
   verifies inside the VPC and reports RTO/RPO):
   ```bash
   scripts/dr-restore-drill.sh --restore-time 2026-11-20T10:14:00Z --keep
   ```
3. Choose a recovery path:
   - **Copy back the lost rows** (preferred, no downtime): connect to the
     restored copy from a one-off task and copy the affected rows into production.
   - **Switch over**: point the app at the restored instance. Rename the old
     instance (`modify-db-instance --new-db-instance-identifier ...-old`), rename
     the restored one to the production identifier, then
     `terraform import`/`apply` to bring it back under management.
4. Delete the restored copy when done (`aws rds delete-db-instance ...`).

## Primary region lost
1. In `dr_region`: `aws rds describe-db-instance-automated-backups` to find the
   replicated backup, then `restore-db-instance-to-point-in-time` with
   `--source-db-instance-automated-backups-arn`.
2. Bring up the rest of the stack in the DR region (`terraform/envs/` with
   `region = <dr_region>`). The images must be in ECR there too (add ECR replication for real production).
