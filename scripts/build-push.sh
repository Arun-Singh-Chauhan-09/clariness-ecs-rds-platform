#!/usr/bin/env bash
# Build and push all six images with one tag (used for the first deploy; CI does the same).
# Usage: scripts/build-push.sh <tag>
source "$(dirname "$0")/lib.sh"
TAG="${1:?usage: build-push.sh <tag>}"
REGISTRY="$(tfo ecr_registry)"
REGION="${REGISTRY#*.dkr.ecr.}"; REGION="${REGION%%.*}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

while read -r repo context; do
  log "building $repo from $context"
  docker build --platform linux/amd64 -t "$REGISTRY/$repo:$TAG" "$REPO_ROOT/$context"
  docker push "$REGISTRY/$repo:$TAG"
done <<'LIST'
referrals-api app
referrals-fluent-bit observability/fluent-bit
referrals-prometheus observability/prometheus
referrals-alertmanager observability/alertmanager
referrals-loki observability/loki
referrals-grafana observability/grafana
LIST
