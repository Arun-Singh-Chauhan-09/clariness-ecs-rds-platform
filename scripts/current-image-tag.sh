#!/usr/bin/env bash
# Print the image tag the API service is running now (used by the drift check).
source "$(dirname "$0")/lib.sh"
CLUSTER="$(tfo cluster_name)"
SERVICE="$(tfo api_service_name)"
TD="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)"
IMAGE="$(aws ecs describe-task-definition --task-definition "$TD" \
  --query 'taskDefinition.containerDefinitions[?name==`app`].image | [0]' --output text)"
echo "${IMAGE##*:}"
