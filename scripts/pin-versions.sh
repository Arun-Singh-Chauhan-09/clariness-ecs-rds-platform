#!/usr/bin/env bash
# Pin GitHub Actions to commit SHAs and container base images to digests.
#
# Tags like `actions/checkout@v4` or `python:3.12-slim` can be moved to point
# at different code; a SHA or digest cannot. Run this once (and Dependabot keeps
# the pins current afterwards):  scripts/pin-versions.sh && git diff
# Needs: gh (logged in), docker (with buildx).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== GitHub Actions -> commit SHAs"
for action in $(grep -rhoE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@v[0-9][A-Za-z0-9_.-]*' .github/workflows | sed 's/uses: //' | sort -u); do
  repo="${action%@*}"; ref="${action#*@}"
  repo_root="$(cut -d/ -f1-2 <<<"$repo")"
  sha="$(gh api "repos/$repo_root/commits/$ref" --jq .sha)"
  echo "  $action -> $sha"
  sed -i "s#uses: $repo@$ref\$#uses: $repo@$sha  \# $ref#; s#uses: $repo@$ref #uses: $repo@$sha  \# $ref #" .github/workflows/*.yml
done

echo "== Dockerfile base images and CI tool images -> digests"
pin_image() {  # $1 = image:tag  -> prints image:tag@sha256:...
  local digest
  digest="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"
  echo "$1@$digest"
}
for f in app/Dockerfile observability/*/Dockerfile; do
  for img in $(grep -E '^FROM ' "$f" | awk '{print $2}' | grep -v '@sha256:' | sort -u); do
    pinned="$(pin_image "$img")"
    echo "  $f: $img -> $pinned"
    sed -i "s#^FROM $img\b#FROM $pinned#" "$f"
  done
done
for img in aquasec/trivy:latest zricethezav/gitleaks:latest; do
  pinned="$(pin_image "$img")"
  echo "  ci.yml: $img -> $pinned"
  sed -i "s#$img #$pinned #" .github/workflows/ci.yml
done

echo "Done. Review with: git diff"
