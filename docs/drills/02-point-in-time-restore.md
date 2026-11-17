# Drill 02: accidental delete, point-in-time restore

## Scenario
A one-off script deletes all referrals for one study. Backups are of no use
unless a restore has actually been done and timed.

## Hypothesis
PITR to one minute before the delete returns all rows. RTO <= 30 min, RPO <= 5 min.

## Run it (AWS)
```bash
scripts/seed.py --base-url "$(terraform -chdir=terraform/envs/staging output -raw api_base_url)"
date -u +%Y-%m-%dT%H:%M:%SZ        # note: BEFORE_DELETE
sleep 360                          # let transaction logs ship (every ~5 min)

# the "accident"
scripts/run-oneoff.sh python -c "from sqlalchemy import text; from referrals.db import engine; c = engine.connect(); print(c.execute(text('DELETE FROM referrals WHERE study_id = 1')).rowcount); c.commit()"

scripts/dr-restore-drill.sh --restore-time <BEFORE_DELETE> --min-studies 4
```
The script writes `results/dr-restore-<date>.md` with RTO, RPO and the row
counts of the restored copy. Compare its `referrals` count with production.

## Observed (fill in after running)
- Date:
- Rows deleted:
- Rows in restored copy:
- RTO / RPO (from the report):
- What I would change:
