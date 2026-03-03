#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="liteskill-test-pg-$$"

docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD=postgres \
  -p 0:5432 \
  pgvector/pgvector:pg18 > /dev/null

MAPPED_PORT=$(docker port "$CONTAINER_NAME" 5432 | head -1 | cut -d: -f2)

cleanup() { docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT

until docker exec "$CONTAINER_NAME" pg_isready -U postgres -q 2>/dev/null; do sleep 0.3; done

export DATABASE_URL="ecto://postgres:postgres@localhost:${MAPPED_PORT}/liteskill_test"
export MIX_ENV=test

mix "${@:-test}"
