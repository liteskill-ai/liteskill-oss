#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the Docker Compose stack: build, boot, verify HTTP, tear down.
# Used by CI (docker-smoke job) and locally via `mix precommit`.

PROJECT="liteskill-smoke-$$"
COMPOSE="docker compose -p $PROJECT"

cleanup() {
  echo "--- Tearing down ---"
  $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "--- Building images ---"
$COMPOSE build

echo "--- Starting services (waiting for healthy) ---"
$COMPOSE up -d --wait --wait-timeout 120

echo "--- Verifying HTTP response ---"
HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' http://localhost:4000)
if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 500 ]]; then
  echo "FAIL: expected 2xx/3xx/4xx, got $HTTP_CODE"
  $COMPOSE logs app
  exit 1
fi

echo "OK: Docker smoke test passed (HTTP $HTTP_CODE)"
