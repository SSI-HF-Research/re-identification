#!/bin/bash
set -euo pipefail
ORIG_DIR="$PWD"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ORIG_DIR
cd "$ROOT"

case "${1:-}" in
  up)
    ./scripts/01-generate.sh
    cd network
    docker compose -f docker-compose.yaml up -d --remove-orphans
    cd ..
    ./scripts/02-start.sh
    echo ">> waiting for orderer to start..."
    #sleep 5
    ./scripts/03-create-channels.sh
    #sleep 10
    ./scripts/04-join-peers.sh
    echo ""
    echo "=================================================="
    echo " Network is up and running."
    echo "  warehouse-channel: OrgIM, OrgWPI, OrgHDW, OrgMO, OrgRO OrgEC1, OrgEC2, OrgEC3"
    echo "  study-channel: OrgSC, OrgSPI, OrgMO, OrgRO OrgEC1, OrgEC2, OrgEC3"
    echo "=================================================="
    ;;
  down)
    cd network
    docker compose -f docker-compose.yaml down -v --remove-orphans || true
    docker ps -a --format '{{.Names}}' | grep 'example.com' | xargs -r docker rm -f || true
    docker ps -a --format '{{.Names}}' | grep '^dev-'       | xargs -r docker rm -f || true
    docker volume ls --format '{{.Name}}' | grep '^network_' | xargs -r docker volume rm || true
    cd ..
    rm -rf network/crypto-config network/channel-artifacts
    echo ">> Network taken down and artifacts cleaned."
    ;;
  status)
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "example.com|NAMES" || echo "no container running."
    ;;
  deployCC)
    shift
    ./scripts/deployCC.sh "$@"
    ;;
  invokeCC)
    shift
    ./scripts/invokeCC.sh "$@"
    ;;
  queryCC)
    shift
    ./scripts/queryCC.sh "$@"
    ;;
  *)
    echo "Use: $0 {up|down|status}"
    exit 1
    ;;
esac
