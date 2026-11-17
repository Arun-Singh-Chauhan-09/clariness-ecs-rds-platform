#!/usr/bin/env bash
# Post-deploy smoke test against the public URL.
# Usage: API_KEY=... scripts/smoke-test.sh <base-url> [expected-version]
set -euo pipefail
: "${API_KEY:?API_KEY must be set (deploy.yml reads it from Secrets Manager)}"
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
unauth="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/studies")"
[[ "$unauth" == "401" ]] || fail "GET /studies without an API key returned $unauth, expected 401"
echo "auth enforced (401 without key)"

status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/studies" -H 'Content-Type: application/json' -H "X-API-Key: $API_KEY" \
  -d "{\"code\":\"$code\",\"display_name\":\"Smoke test study\",\"phase\":\"I\"}")"
[[ "$status" == "201" || "$status" == "409" ]] || fail "POST /studies returned $status"
curl -fsS -H "X-API-Key: $API_KEY" "$BASE/studies?limit=1" >/dev/null || fail "GET /studies"
echo "write + read ok"

metrics="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/metrics")"
[[ "$metrics" == "404" ]] || fail "/metrics is reachable from the internet (HTTP $metrics); the ALB rule should block it"
echo "/metrics blocked at the ALB"
