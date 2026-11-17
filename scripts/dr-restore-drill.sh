#!/usr/bin/env bash
# DRILL 02: point-in-time restore of the production database, verified end to end.
#
#   1. Restore the RDS instance to a point in time, as a NEW instance
#      (PITR never overwrites the source).
#   2. Give the restored copy a temporary password (its own, not production's).
#   3. Run a verification task inside the VPC against the copy.
#   4. Record RTO (time until the copy is verified) and RPO (data-loss window).
#   5. Delete the copy (unless --keep).
#
# Usage: scripts/dr-restore-drill.sh [--restore-time 2026-11-20T10:15:00Z] [--min-studies N] [--keep]
source "$(dirname "$0")/lib.sh"

RESTORE_TIME=""; MIN_STUDIES=1; KEEP=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore-time) RESTORE_TIME="$2"; shift 2 ;;
    --min-studies)  MIN_STUDIES="$2"; shift 2 ;;
    --keep)         KEEP=true; shift ;;
    *) die "unknown argument $1" ;;
  esac
done

load_outputs
SOURCE="$(tfo db_instance_id)"
TARGET="${SOURCE}-drill-$(date -u +%m%d%H%M)"
RESULTS_DIR="$REPO_ROOT/docs/drills/results"
mkdir -p "$RESULTS_DIR"

LATEST_RESTORABLE="$(aws rds describe-db-instances --db-instance-identifier "$SOURCE" \
  --query 'DBInstances[0].LatestRestorableTime' --output text)"
log "source $SOURCE, latest restorable time $LATEST_RESTORABLE"

if [[ -n "$RESTORE_TIME" ]]; then
  TIME_ARGS=(--restore-time "$RESTORE_TIME")
else
  TIME_ARGS=(--use-latest-restorable-time)
fi

T0=$(date +%s)
log "restoring to $TARGET ..."
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SOURCE" \
  --target-db-instance-identifier "$TARGET" \
  "${TIME_ARGS[@]}" \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name "$(tfo db_subnet_group)" \
  --vpc-security-group-ids "$(tfo db_security_group_id)" \
  --db-parameter-group-name "$(tfo db_parameter_group)" \
  --no-multi-az --no-publicly-accessible --no-deletion-protection \
  --tags Key=Purpose,Value=dr-drill >/dev/null

cleanup() {
  if [[ "$KEEP" == false ]]; then
    log "deleting $TARGET"
    aws rds delete-db-instance --db-instance-identifier "$TARGET" \
      --skip-final-snapshot --delete-automated-backups >/dev/null || log "delete failed: remove $TARGET by hand"
  else
    log "--keep: $TARGET is still running and costs money"
  fi
}
trap cleanup EXIT

# The waiter gives up after 30 minutes; a restore can take longer, so retry.
for _ in 1 2 3; do aws rds wait db-instance-available --db-instance-identifier "$TARGET" && break; done
T1=$(date +%s)
log "instance available after $((T1 - T0)) s"

# Temporary password for the copy only. Production's secret is untouched.
TMP_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
if ! aws rds modify-db-instance --db-instance-identifier "$TARGET" --apply-immediately \
      --no-manage-master-user-password --master-user-password "$TMP_PASSWORD" >/dev/null 2>&1; then
  aws rds modify-db-instance --db-instance-identifier "$TARGET" --apply-immediately \
    --master-user-password "$TMP_PASSWORD" >/dev/null
fi
sleep 30
aws rds wait db-instance-available --db-instance-identifier "$TARGET"
ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$TARGET" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"

# Note: container overrides are visible in DescribeTasks. Acceptable here because
# the password belongs to a throwaway copy that is deleted at the end of the drill.
OVERRIDES="$(python3 -c '
import json, sys
host, pw, n = sys.argv[1:]
print(json.dumps({"containerOverrides": [{
    "name": "app",
    "command": ["python", "-m", "referrals.verify_restore"],
    "environment": [
        {"name": "DB_HOST", "value": host},
        {"name": "DRILL_DB_PASSWORD", "value": pw},
        {"name": "MIN_EXPECTED_STUDIES", "value": n},
    ],
}]}))' "$ENDPOINT" "$TMP_PASSWORD" "$MIN_STUDIES")"

TASK_ARN="$(run_task "$MIGRATE_FAMILY" "$OVERRIDES" "dr-drill")"
set +e
VERIFY_LOG="$(wait_task "$TASK_ARN" "/ecs/$MIGRATE_FAMILY" 2>&1)"
VERIFY_EXIT=$?
set -e
echo "$VERIFY_LOG"
T2=$(date +%s)

RESULT_LINE="$(grep -o 'DR_VERIFY .*' <<<"$VERIFY_LOG" | head -1 | cut -d' ' -f2- || true)"
RPO_S="$(python3 -c '
import sys
from datetime import datetime, timezone
t = sys.argv[1].replace("Z", "+00:00")
print(int((datetime.now(timezone.utc) - datetime.fromisoformat(t)).total_seconds()))' "$LATEST_RESTORABLE")"

REPORT="$RESULTS_DIR/dr-restore-$(date -u +%Y-%m-%d-%H%M).md"
cat > "$REPORT" <<MD
# DR restore drill: $(date -u +%Y-%m-%d\ %H:%M) UTC

| | |
|---|---|
| Source instance | \`$SOURCE\` |
| Restored as | \`$TARGET\` |
| Restore point | ${RESTORE_TIME:-latest restorable ($LATEST_RESTORABLE)} |
| Instance available after | $((T1 - T0)) s |
| **RTO** (start -> data verified) | **$((T2 - T0)) s** (~$(( (T2 - T0) / 60 )) min) |
| **RPO** at drill start (now - latest restorable time) | **${RPO_S} s** |
| Verification | $([[ $VERIFY_EXIT -eq 0 ]] && echo PASSED || echo FAILED) |
| Verification output | \`${RESULT_LINE:-none}\` |

Restored copy deleted after the drill: $([[ "$KEEP" == false ]] && echo yes || echo no)
MD
log "report written to ${REPORT#$REPO_ROOT/}"
[[ $VERIFY_EXIT -eq 0 ]] || die "verification FAILED"
log "drill passed: RTO $((T2 - T0)) s, RPO ${RPO_S} s"
