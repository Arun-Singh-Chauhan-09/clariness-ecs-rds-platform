#!/usr/bin/env bash
# Run any command in a one-off task (app image, DB credentials, private subnet).
# Example: scripts/run-oneoff.sh python -m referrals.verify_restore
source "$(dirname "$0")/lib.sh"
[[ $# -gt 0 ]] || die "usage: run-oneoff.sh <command> [args...]"
load_outputs

OVERRIDES="$(python3 -c 'import json,sys; print(json.dumps({"containerOverrides":[{"name":"app","command":sys.argv[1:]}]}))' "$@")"
TASK_ARN="$(run_task "$MIGRATE_FAMILY" "$OVERRIDES" "oneoff-${USER:-ci}")"
wait_task "$TASK_ARN" "/ecs/$MIGRATE_FAMILY"
