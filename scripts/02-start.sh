#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/network"

echo ">> Starting containers"
docker compose -f docker-compose.yaml up -d

for port in 7051 8051 9051 10051 11051 12051 13051 14051 15051 16051; do
  while ! nc -z localhost $port; do
    echo "waiting for peer on port $port..."
    sleep 2
  done
done

echo ">> Waiting for containers to be ready..."
sleep 10

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "example.com|NAMES"
