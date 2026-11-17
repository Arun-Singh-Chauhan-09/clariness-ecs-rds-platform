#!/usr/bin/env bash
# DRILL 03: Multi-AZ failover under traffic.
# Reboots the primary with --force-failover while polling a DB-backed endpoint
# twice a second, then reports how long the API returned errors.
# Requires db_multi_az = true.
# Usage: scripts/rds-failover-drill.sh
source "$(dirname "$0")/lib.sh"

BASE="$(tfo api_base_url)"
DB="$(tfo db_instance_id)"
RESULTS_DIR="$REPO_ROOT/docs/drills/results"; mkdir -p "$RESULTS_DIR"
PROBE_LOG="$(mktemp)"

[[ "$(aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].MultiAZ' --output text)" == "True" ]] \
  || die "$DB is not Multi-AZ; set db_multi_az = true and apply first"

AZ_BEFORE="$(aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].AvailabilityZone' --output text)"

probe() {
  while true; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$BASE/studies?limit=1" || echo 000)"
    echo "$(date +%s.%N) $code" >> "$PROBE_LOG"
    sleep 0.5
  done
}
probe &
PROBE_PID=$!
trap 'kill $PROBE_PID 2>/dev/null || true' EXIT

log "baseline traffic for 30 s"; sleep 30
T0=$(date +%s)
log "rebooting $DB with forced failover (primary in $AZ_BEFORE)"
aws rds reboot-db-instance --db-instance-identifier "$DB" --force-failover >/dev/null
sleep 20
aws rds wait db-instance-available --db-instance-identifier "$DB"
T1=$(date +%s)
log "instance available again after $((T1 - T0)) s; probing 60 s more"
sleep 60
kill "$PROBE_PID"

AZ_AFTER="$(aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].AvailabilityZone' --output text)"

SUMMARY="$(python3 - "$PROBE_LOG" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
bad = [float(t) for t, c in rows if not c.startswith("2")]
total = len(rows)
if bad:
    window = bad[-1] - bad[0]
    print(f"{len(bad)} of {total} probes failed; error window {window:.1f} s "
          f"(first {bad[0]:.0f}, last {bad[-1]:.0f})")
else:
    print(f"0 of {total} probes failed")
PY
)"

REPORT="$RESULTS_DIR/rds-failover-$(date -u +%Y-%m-%d-%H%M).md"
cat > "$REPORT" <<MD
# RDS Multi-AZ failover drill: $(date -u +%Y-%m-%d\ %H:%M) UTC

| | |
|---|---|
| Instance | \`$DB\` |
| Primary AZ before / after | $AZ_BEFORE / $AZ_AFTER |
| Reboot -> instance available | $((T1 - T0)) s |
| API impact (GET /studies every 0.5 s) | $SUMMARY |
MD
log "$SUMMARY"
log "report written to ${REPORT#$REPO_ROOT/}"
