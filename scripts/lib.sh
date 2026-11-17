# Shared helpers for the operational scripts. Source it, don't run it.
# Requires: aws CLI v2, terraform (initialised in $TF_DIR), python3.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform/envs/staging}"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

tfo() { terraform -chdir="$TF_DIR" output -raw "$1"; }

load_outputs() {
  CLUSTER="$(tfo cluster_name)"
  SUBNETS="$(tfo private_subnet_ids)"
  ONEOFF_SG="$(tfo migrate_security_group_id)"
  MIGRATE_FAMILY="$(tfo migrate_task_family)"
}

# run_task <task-definition> <overrides-json> <started-by>  -> prints the task ARN
run_task() {
  local arn
  arn="$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$1" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$ONEOFF_SG],assignPublicIp=DISABLED}" \
    --overrides "$2" \
    --started-by "$3" \
    --query 'tasks[0].taskArn' --output text)"
  [[ "$arn" == arn:* ]] || die "run-task did not start a task (got: $arn)"
  echo "$arn"
}

# wait_task <task-arn> <log-group>  -> prints the container logs, returns the container exit code
wait_task() {
  local arn="$1" group="$2" task_id exit_code reason
  task_id="${arn##*/}"
  log "waiting for task $task_id ..."
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$arn"

  exit_code="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" \
    --query 'tasks[0].containers[?name==`app`].exitCode | [0]' --output text)"
  reason="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" \
    --query 'tasks[0].stoppedReason' --output text)"

  log "logs ($group, app/app/$task_id):"
  aws logs get-log-events --log-group-name "$group" --log-stream-name "app/app/$task_id" \
    --start-from-head --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' || true

  if [[ "$exit_code" == "None" || -z "$exit_code" ]]; then
    log "task stopped without an exit code: $reason"
    return 1
  fi
  log "exit code $exit_code ($reason)"
  return "$exit_code"
}
