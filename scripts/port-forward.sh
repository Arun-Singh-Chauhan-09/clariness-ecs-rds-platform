#!/usr/bin/env bash
# Open a private observability UI on localhost through ECS Exec / SSM.
# Nothing is exposed to the internet: no ALB rule, no public IP, no open port.
# Needs the AWS Session Manager plugin installed locally.
# Usage: scripts/port-forward.sh grafana|prometheus|alertmanager|loki [local-port]
source "$(dirname "$0")/lib.sh"

COMPONENT="${1:?usage: port-forward.sh grafana|prometheus|alertmanager|loki [local-port]}"
case "$COMPONENT" in
  grafana) PORT=3000 ;; prometheus) PORT=9090 ;; alertmanager) PORT=9093 ;; loki) PORT=3100 ;;
  *) die "unknown component $COMPONENT" ;;
esac
LOCAL_PORT="${2:-$PORT}"

CLUSTER="$(tfo cluster_name)"
SERVICE="$(terraform -chdir="$TF_DIR" output -json observability_services \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$COMPONENT")"
TASK_ARN="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns[0]' --output text)"
[[ "$TASK_ARN" == arn:* ]] || die "no running task for $SERVICE"
TASK_ID="${TASK_ARN##*/}"
RUNTIME_ID="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[?name==`app`].runtimeId | [0]' --output text)"

if [[ "$COMPONENT" == "grafana" ]]; then
  SECRET="$(tfo grafana_admin_secret_arn)"
  log "Grafana login: admin / $(aws secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text)"
fi
log "$COMPONENT -> http://localhost:$LOCAL_PORT (Ctrl+C to stop)"
aws ssm start-session \
  --target "ecs:${CLUSTER}_${TASK_ID}_${RUNTIME_ID}" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"$PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
