#!/usr/bin/env bash
# CityBike SDLC - local five-gate promotion pipeline (Lab 04, Path B)
# Usage: ./scripts/pipeline.sh <image:tag>      e.g. ./scripts/pipeline.sh citybike:v1
#
# Builds nothing: the SAME immutable image is promoted Staging -> UAT -> OAT -> Preprod -> Prod.
# Gates 1-4 run in a temporary container (citybike-gate) on host port 4174 so the live
# production container (citybike-prod, host port 4173) is only replaced after Preprod passes.
# The first failing gate stops the pipeline; nothing after it runs.
set -euo pipefail

IMAGE="${1:?usage: $0 <image:tag>}"
PROD_API_KEY="${PROD_API_KEY:-lab-secret}"     # in CI this comes from the PROD_API_KEY secret
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"         # seconds to wait for /health
GATE_NAME=citybike-gate
GATE_PORT=4174
PROD_NAME=citybike-prod
PROD_PORT=4173

cd "$(dirname "$0")/.."

banner() { printf '\n\033[1;34m==== %s ====\033[0m\n' "$*"; }
fail()   { printf '\n\033[1;31mPIPELINE STOPPED: gate "%s" failed - %s\033[0m\n' "$1" "$2"; exit 1; }

# Poll /health in a real retry loop; give up early if the container died.
wait_for_health() {
  local url=$1 name=$2 i
  for ((i = 1; i <= HEALTH_TIMEOUT; i++)); do
    if curl -sf "${url}/health" >/dev/null 2>&1; then
      echo "  /health ready after ${i} attempt(s)"
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
      echo "  container ${name} is not running (exit code $(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null)). Last logs:"
      docker logs --tail 15 "$name" 2>&1 | sed 's/^/    | /'
      return 1
    fi
    sleep 1
  done
  echo "  /health did not answer within ${HEALTH_TIMEOUT}s. Last logs:"
  docker logs --tail 15 "$name" 2>&1 | sed 's/^/    | /'
  return 1
}

cleanup_gate() { docker rm -f "$GATE_NAME" >/dev/null 2>&1 || true; }
trap cleanup_gate EXIT

# Gates 1-4: <gate> [extra docker run args...]
run_gate() {
  local gate=$1; shift
  banner "Gate: ${gate}  (image ${IMAGE})"
  cleanup_gate                                                         # 1. remove leftovers
  docker run -d --name "$GATE_NAME" -p "${GATE_PORT}:4173" "$@" "$IMAGE" >/dev/null \
    || fail "$gate" "container did not start"                          # 2. start detached
  wait_for_health "http://localhost:${GATE_PORT}" "$GATE_NAME" \
    || { cleanup_gate; fail "$gate" "service never became healthy"; }  # 3. poll /health
  TARGET_URL="http://localhost:${GATE_PORT}" IMAGE_NAME="$IMAGE" "./scripts/test-${gate}.sh" \
    || { cleanup_gate; fail "$gate" "test-${gate}.sh exited non-zero"; } # 4. run gate script
  cleanup_gate                                                         # 5. clean up
  printf '\033[1;32m  gate %s: PASSED\033[0m\n' "$gate"
}

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "pre-check" "image ${IMAGE} not found (build it first)"
echo "Promoting ${IMAGE} ($(docker image inspect "$IMAGE" --format '{{.Id}}' | cut -c8-19)) through 5 gates"

run_gate staging -e APP_ENV=staging
run_gate uat     -e APP_ENV=uat
run_gate oat     -e APP_ENV=oat
run_gate preprod -e APP_ENV=preprod -e PROD_API_KEY="$PROD_API_KEY"

# Gate 5: Prod - replace citybike-prod on port 4173 and leave it running.
banner "Gate: prod  (image ${IMAGE})"
PREVIOUS_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$PROD_NAME" 2>/dev/null || true)"
docker rm -f "$PROD_NAME" >/dev/null 2>&1 || true
docker run -d --name "$PROD_NAME" -p "${PROD_PORT}:4173" \
  -e APP_ENV=production -e PROD_API_KEY="$PROD_API_KEY" "$IMAGE" >/dev/null
if wait_for_health "http://localhost:${PROD_PORT}" "$PROD_NAME" \
   && TARGET_URL="http://localhost:${PROD_PORT}" ./scripts/test-prod.sh; then
  printf '\033[1;32m  gate prod: PASSED\033[0m\n'
  printf '\n\033[1;32mPIPELINE GREEN: %s is live in production on port %s\033[0m\n' "$IMAGE" "$PROD_PORT"
else
  if [ -n "$PREVIOUS_IMAGE" ]; then
    echo "  rolling production back to ${PREVIOUS_IMAGE}"
    docker rm -f "$PROD_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$PROD_NAME" -p "${PROD_PORT}:4173" \
      -e APP_ENV=production -e PROD_API_KEY="$PROD_API_KEY" "$PREVIOUS_IMAGE" >/dev/null
  fi
  fail prod "production smoke test failed"
fi
