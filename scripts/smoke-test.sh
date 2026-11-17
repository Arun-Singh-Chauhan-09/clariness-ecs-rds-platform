#!/usr/bin/env bash
# Post-deploy smoke test against the public URL.
# Usage: scripts/smoke-test.sh <base-url> [expected-version]
set -euo pipefail
BASE="${1:?usage: smoke-test.sh <base-url> [expected-version]}"
EXPECTED="${2:-}"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

# The ALB may still route a few requests to draining tasks right after a
# deployment, so retry the version check for up to 60 s.
for _ in $(seq 1 12); do
  version="$(curl -fsS "$BASE/healthz" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" || version=""
  [[ -z "$EXPECTED" || "$version" == "$EXPECTED" ]] && break
  sleep 5
done
[[ -z "$EXPECTED" || "$version" == "$EXPECTED" ]] || fail "serving version '$version', expected '$EXPECTED'"
echo "healthz ok (version $version)"

curl -fsS "$BASE/readyz" >/dev/null || fail "/readyz"
echo "readyz ok"

code="SMK-2026-$(printf '%03d' $((RANDOM % 1000)))"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/studies" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$code\",\"display_name\":\"Smoke test study\",\"phase\":\"I\"}")"
[[ "$status" == "201" || "$status" == "409" ]] || fail "POST /studies returned $status"
curl -fsS "$BASE/studies?limit=1" >/dev/null || fail "GET /studies"
echo "write + read ok"
