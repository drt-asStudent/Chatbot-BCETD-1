#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# CHATBOT BCETD Agent — Startup Script
# Member 1 Deliverable: Infrastructure & DevOps Lead
#
# Usage:
#   ./member1-infrastructure/scripts/start.sh              Start core services (n8n, Qdrant, Postgres, Frontend)
#   ./member1-infrastructure/scripts/start.sh --all        Start everything including Ollama + Grafana
#   ./member1-infrastructure/scripts/start.sh --ollama     Start core + Ollama (local LLM)
#   ./member1-infrastructure/scripts/start.sh --monitoring Start core + Grafana
#   ./member1-infrastructure/scripts/start.sh --stop       Stop all services
#   ./member1-infrastructure/scripts/start.sh --status     Show status of all services
#   ./member1-infrastructure/scripts/start.sh --reset      Stop + delete all data (DESTRUCTIVE)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Navigate to project root ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# ── Banner ──
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CHATBOT BCETD Agent — Infrastructure Manager${NC}"
echo -e "${BLUE}  Universitatea Lucian Blaga din Sibiu${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# COMMAND ROUTING
# ═══════════════════════════════════════════════════════════════

ACTION="${1:---core}"
PROFILES=""

case "$ACTION" in
  --stop)
    echo -e "${YELLOW}[STOP]${NC} Shutting down all services..."
    docker compose --profile ollama --profile monitoring down
    echo -e "${GREEN}All services stopped.${NC}"
    exit 0
    ;;
  --status)
    echo -e "${CYAN}[STATUS]${NC} Service status:"
    echo ""
    docker compose --profile ollama --profile monitoring ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
    docker compose --profile ollama --profile monitoring ps
    exit 0
    ;;
  --reset)
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: This will DELETE ALL DATA permanently!    ║${NC}"
    echo -e "${RED}║  • All n8n workflows and credentials                ║${NC}"
    echo -e "${RED}║  • All Qdrant vector embeddings                     ║${NC}"
    echo -e "${RED}║  • All PostgreSQL analytics data                    ║${NC}"
    echo -e "${RED}║  • All Ollama downloaded models                     ║${NC}"
    echo -e "${RED}║  • All Grafana dashboards                           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Type 'RESET' to confirm: " CONFIRM
    if [ "$CONFIRM" = "RESET" ]; then
      docker compose --profile ollama --profile monitoring down -v
      echo -e "${GREEN}All services stopped and data deleted.${NC}"
    else
      echo "Aborted."
    fi
    exit 0
    ;;
  --all)
    PROFILES="--profile ollama --profile monitoring"
    echo -e "${CYAN}Mode:${NC} Full stack (core + Ollama + Grafana)"
    ;;
  --ollama)
    PROFILES="--profile ollama"
    echo -e "${CYAN}Mode:${NC} Core + Ollama (local LLM)"
    ;;
  --monitoring)
    PROFILES="--profile monitoring"
    echo -e "${CYAN}Mode:${NC} Core + Grafana monitoring"
    ;;
  --core|*)
    PROFILES=""
    echo -e "${CYAN}Mode:${NC} Core services only (n8n, Qdrant, Postgres, Frontend)"
    ;;
esac

# ═══════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}[1/5] Pre-flight checks...${NC}"

# Check Docker
if ! command -v docker &>/dev/null; then
  echo -e "${RED}ERROR: Docker is not installed.${NC}"
  echo "  Install Docker: https://docs.docker.com/get-docker/"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} Docker found: $(docker --version | head -c 50)"

# Check Docker Compose
if ! docker compose version &>/dev/null; then
  echo -e "${RED}ERROR: Docker Compose V2 is not available.${NC}"
  echo "  Docker Compose V2 is included with Docker Desktop."
  echo "  On Linux: https://docs.docker.com/compose/install/linux/"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} Docker Compose: $(docker compose version --short 2>/dev/null || echo 'v2')"

# Check Docker daemon
if ! docker info &>/dev/null; then
  echo -e "${RED}ERROR: Docker daemon is not running.${NC}"
  echo "  Start Docker Desktop or run: sudo systemctl start docker"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} Docker daemon is running"

# Check .env file
if [ ! -f ".env" ]; then
  echo -e "${YELLOW}  ⚠ No .env file found. Creating from .env.example...${NC}"
  if [ -f ".env.example" ]; then
    cp .env.example .env
    echo -e "  ${GREEN}✓${NC} Created .env from template"
    echo -e "  ${YELLOW}  → Edit .env and set your OPENAI_API_KEY before using the chat${NC}"
  else
    echo -e "${RED}ERROR: No .env.example found. Cannot continue.${NC}"
    exit 1
  fi
else
  echo -e "  ${GREEN}✓${NC} .env file found"
fi

# Check for OpenAI API key
source .env 2>/dev/null || true
if [ -z "${OPENAI_API_KEY:-}" ] || [ "$OPENAI_API_KEY" = "sk-your-api-key-here" ]; then
  echo -e "  ${YELLOW}⚠ OPENAI_API_KEY is not set. The chatbot won't work until you set it.${NC}"
  echo -e "  ${YELLOW}  → Edit .env and add your OpenAI API key${NC}"
  echo -e "  ${YELLOW}  → Or use Ollama for fully local operation (--ollama flag)${NC}"
else
  echo -e "  ${GREEN}✓${NC} OPENAI_API_KEY is configured"
fi

# Ensure documents directory exists
DOCS_DIR="${DOCUMENTS_PATH:-./data/documents}"
if [ ! -d "$DOCS_DIR" ]; then
  mkdir -p "$DOCS_DIR"
  echo -e "  ${GREEN}✓${NC} Created documents directory: $DOCS_DIR"
else
  DOC_COUNT=$(find "$DOCS_DIR" -type f \( -name "*.pdf" -o -name "*.docx" -o -name "*.txt" -o -name "*.html" \) 2>/dev/null | wc -l)
  echo -e "  ${GREEN}✓${NC} Documents directory: $DOCS_DIR ($DOC_COUNT files found)"
fi

# Ensure backups directory exists
mkdir -p "${BACKUP_DIR:-./backups/postgres}" 2>/dev/null || true

# Check Dockerfile exists for frontend build
if [ ! -f "member5-frontend-python/Dockerfile" ]; then
  echo -e "  ${YELLOW}⚠ member5-frontend-python/Dockerfile not found. Frontend won't build.${NC}"
else
  echo -e "  ${GREEN}✓${NC} Frontend Dockerfile found"
fi

# ═══════════════════════════════════════════════════════════════
# PORT AVAILABILITY CHECK
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}[2/5] Checking port availability...${NC}"

check_port() {
  local PORT=$1
  local SERVICE=$2
  if lsof -i :"$PORT" &>/dev/null || ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    echo -e "  ${RED}✗ Port $PORT is in use ($SERVICE)${NC}"
    echo -e "    → Change ${SERVICE}_PORT in .env or stop the conflicting process"
    return 1
  else
    echo -e "  ${GREEN}✓${NC} Port $PORT available ($SERVICE)"
    return 0
  fi
}

PORT_OK=true
check_port "${N8N_PORT:-5678}" "n8n" || PORT_OK=false
check_port "${QDRANT_PORT:-6333}" "Qdrant" || PORT_OK=false
check_port "${POSTGRES_PORT:-5432}" "PostgreSQL" || PORT_OK=false
check_port "${FRONTEND_PORT:-3000}" "Frontend" || PORT_OK=false

if echo "$PROFILES" | grep -q "ollama"; then
  check_port "${OLLAMA_PORT:-11434}" "Ollama" || PORT_OK=false
fi
if echo "$PROFILES" | grep -q "monitoring"; then
  check_port "${GRAFANA_PORT:-3001}" "Grafana" || PORT_OK=false
fi

if [ "$PORT_OK" = false ]; then
  echo ""
  echo -e "${YELLOW}Some ports are in use. Continuing anyway (Docker may rebind)...${NC}"
fi

# ═══════════════════════════════════════════════════════════════
# LAUNCH SERVICES
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}[3/5] Building and starting services...${NC}"

docker compose $PROFILES up -d --build 2>&1 | while IFS= read -r line; do
  echo "  $line"
done

# ═══════════════════════════════════════════════════════════════
# HEALTH CHECK LOOP
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}[4/5] Waiting for services to become healthy...${NC}"

wait_for_service() {
  local NAME=$1
  local URL=$2
  local MAX_WAIT=$3
  local ELAPSED=0

  printf "  %-14s " "$NAME"
  while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -sf "$URL" &>/dev/null; then
      echo -e "${GREEN}✓ healthy${NC} (${ELAPSED}s)"
      return 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    printf "."
  done
  echo -e "${RED}✗ timeout after ${MAX_WAIT}s${NC}"
  return 1
}

ALL_HEALTHY=true

wait_for_service "PostgreSQL" "http://localhost:${POSTGRES_PORT:-5432}" 30 2>/dev/null || {
  # pg_isready doesn't speak HTTP — check via docker
  printf "  %-14s " "PostgreSQL"
  for i in $(seq 1 15); do
    if docker exec bcetd-postgres pg_isready -U "${POSTGRES_USER:-chatbot_user}" &>/dev/null; then
      echo -e "${GREEN}✓ healthy${NC} ($((i*2))s)"
      break
    fi
    sleep 2
    printf "."
    [ $i -eq 15 ] && { echo -e "${RED}✗ timeout${NC}"; ALL_HEALTHY=false; }
  done
}

wait_for_service "Qdrant" "http://localhost:${QDRANT_PORT:-6333}/readyz" 30 || ALL_HEALTHY=false
wait_for_service "n8n" "http://localhost:${N8N_PORT:-5678}/healthz" 60 || ALL_HEALTHY=false
wait_for_service "Frontend" "http://localhost:${FRONTEND_PORT:-3000}/health" 30 || ALL_HEALTHY=false

if echo "$PROFILES" | grep -q "ollama"; then
  wait_for_service "Ollama" "http://localhost:${OLLAMA_PORT:-11434}/api/version" 90 || ALL_HEALTHY=false
fi
if echo "$PROFILES" | grep -q "monitoring"; then
  wait_for_service "Grafana" "http://localhost:${GRAFANA_PORT:-3001}/api/health" 30 || ALL_HEALTHY=false
fi

# ═══════════════════════════════════════════════════════════════
# POST-START SUMMARY
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}[5/5] Startup complete!${NC}"
echo ""

if [ "$ALL_HEALTHY" = true ]; then
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  All services are running and healthy!${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
else
  echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  Some services may still be starting. Check status with:${NC}"
  echo -e "${YELLOW}  ./member1-infrastructure/scripts/start.sh --status${NC}"
  echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
fi

echo ""
echo -e "${BOLD}  Access Points:${NC}"
echo -e "  ─────────────────────────────────────────────────────"
echo -e "  ${CYAN}Chat UI:${NC}          http://localhost:${FRONTEND_PORT:-3000}"
echo -e "  ${CYAN}Admin Dashboard:${NC}  http://localhost:${FRONTEND_PORT:-3000}/admin"
echo -e "  ${CYAN}n8n Workflows:${NC}    http://localhost:${N8N_PORT:-5678}"
echo -e "  ${CYAN}Qdrant Dashboard:${NC} http://localhost:${QDRANT_PORT:-6333}/dashboard"
if echo "$PROFILES" | grep -q "monitoring"; then
  echo -e "  ${CYAN}Grafana:${NC}          http://localhost:${GRAFANA_PORT:-3001}"
fi
echo ""
echo -e "${BOLD}  Next Steps:${NC}"
echo "  1. Open n8n and import the workflow JSON files"
echo "  2. Place ULBS documents in ${DOCS_DIR}"
echo "  3. Run the ingestion pipeline in n8n"
echo "  4. Open the Chat UI and start testing!"
if echo "$PROFILES" | grep -q "ollama"; then
  echo ""
  echo -e "  ${YELLOW}Ollama:${NC} Pull models with:"
  echo "    docker exec bcetd-ollama ollama pull llama3.1"
  echo "    docker exec bcetd-ollama ollama pull nomic-embed-text"
fi
echo ""
