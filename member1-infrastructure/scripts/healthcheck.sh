#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# CHATBOT BCETD — Service Health Check
# Member 1 Deliverable
#
# Usage: ./member1-infrastructure/scripts/healthcheck.sh
# Returns exit code 0 if all services healthy, 1 otherwise
# Suitable for cron monitoring or uptime checks
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

HEALTHY=0
UNHEALTHY=0

check() {
  local NAME=$1
  local CMD=$2
  printf "  %-18s " "$NAME"
  if eval "$CMD" &>/dev/null; then
    echo -e "${GREEN}✓ healthy${NC}"
    HEALTHY=$((HEALTHY+1))
  else
    echo -e "${RED}✗ unhealthy${NC}"
    UNHEALTHY=$((UNHEALTHY+1))
  fi
}

echo ""
echo "BCETD Service Health Check — $(date)"
echo "──────────────────────────────────────────"

# Core services
check "PostgreSQL"  "docker exec bcetd-postgres pg_isready -U ${POSTGRES_USER:-chatbot_user}"
check "Qdrant"      "curl -sf http://localhost:${QDRANT_PORT:-6333}/readyz"
check "n8n"         "curl -sf http://localhost:${N8N_PORT:-5678}/healthz"
check "Frontend"    "curl -sf http://localhost:${FRONTEND_PORT:-3000}/health"

# Optional services (only check if container exists)
if docker ps --format '{{.Names}}' | grep -q bcetd-ollama; then
  check "Ollama" "curl -sf http://localhost:${OLLAMA_PORT:-11434}/api/version"
fi
if docker ps --format '{{.Names}}' | grep -q bcetd-grafana; then
  check "Grafana" "curl -sf http://localhost:${GRAFANA_PORT:-3001}/api/health"
fi

# Data integrity checks
printf "  %-18s " "Qdrant collection"
QDRANT_INFO=$(curl -sf "http://localhost:${QDRANT_PORT:-6333}/collections/ulbs_documents" 2>/dev/null)
if [ $? -eq 0 ]; then
  VECTORS=$(echo "$QDRANT_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('vectors_count',0))" 2>/dev/null || echo "?")
  echo -e "${GREEN}✓${NC} $VECTORS vectors"
  HEALTHY=$((HEALTHY+1))
else
  echo -e "${RED}✗ not found${NC}"
  UNHEALTHY=$((UNHEALTHY+1))
fi

printf "  %-18s " "PostgreSQL tables"
TABLE_COUNT=$(docker exec bcetd-postgres psql -U "${POSTGRES_USER:-chatbot_user}" -d "${POSTGRES_DB:-chatbot_stats}" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo "0")
if [ "$TABLE_COUNT" -gt 0 ] 2>/dev/null; then
  echo -e "${GREEN}✓${NC} $TABLE_COUNT tables"
  HEALTHY=$((HEALTHY+1))
else
  echo -e "${RED}✗ no tables${NC}"
  UNHEALTHY=$((UNHEALTHY+1))
fi

# Disk usage
echo ""
echo "  Disk Usage:"
docker system df --format "  {{.Type}}\t{{.Size}}\t({{.Reclaimable}} reclaimable)" 2>/dev/null || true

# Summary
echo ""
echo "──────────────────────────────────────────"
TOTAL=$((HEALTHY+UNHEALTHY))
echo "  $HEALTHY/$TOTAL healthy"

if [ $UNHEALTHY -gt 0 ]; then
  echo -e "  ${RED}Some services are unhealthy!${NC}"
  exit 1
fi

echo -e "  ${GREEN}All services operational.${NC}"
exit 0
