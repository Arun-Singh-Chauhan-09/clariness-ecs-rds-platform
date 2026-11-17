#!/usr/bin/env bash
# Run `alembic upgrade head` from a given image as a one-off ECS task, BEFORE
# the service is updated (expand migrations must land before the new code).
# Usage: scripts/run-migration.sh <image-uri>
source "$(dirname "$0")/lib.sh"

IMAGE="${1:?usage: run-migration.sh <image-uri>}"
load_outputs

log "registering $MIGRATE_FAMILY with image $IMAGE"
aws ecs describe-task-definition --task-definition "$MIGRATE_FAMILY" --query taskDefinition --output json \
  | python3 -c '
import json, sys
td = json.load(sys.stdin)
keep = ["family", "taskRoleArn", "executionRoleArn", "networkMode", "containerDefinitions",
        "requiresCompatibilities", "cpu", "memory", "runtimePlatform"]
new = {k: td[k] for k in keep if k in td}
for c in new["containerDefinitions"]:
    if c["name"] == "app":
        c["image"] = sys.argv[1]
json.dump(new, open("/tmp/migrate-td.json", "w"))
' "$IMAGE"
TD_ARN="$(aws ecs register-task-definition --cli-input-json file:///tmp/migrate-td.json \
  --query taskDefinition.taskDefinitionArn --output text)"

TASK_ARN="$(run_task "$TD_ARN" '{}' "migration-${GITHUB_SHA:-manual}")"
if wait_task "$TASK_ARN" "/ecs/$MIGRATE_FAMILY"; then
  log "migration finished"
else
  die "migration failed: the service was NOT updated. See docs/runbooks/db-migrations.md"
fi
