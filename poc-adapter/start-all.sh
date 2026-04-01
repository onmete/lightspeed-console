#!/usr/bin/env bash
#
# Launches the full OLS-on-Ambient POC stack:
#   1. Connects to the Ambient backend (via Route or port-forward)
#   2. OLS→Ambient adapter (translates OLS SSE ↔ AG-UI protocol)
#   3. Lightspeed console plugin dev server
#   4. OpenShift console container
#
# Quick start (after cluster setup):
#   ./setup-cluster.sh          # one-time: deploys Ambient + creates session
#   source .env.session && ./start-all.sh   # launches the local UI stack
#
# Or manually:
#   AMBIENT_SESSION=<name> AMBIENT_PROJECT=<project> ./start-all.sh
#   MOCK_MODE=true ./start-all.sh   # no backend needed
#
# Prerequisites:
#   - setup-cluster.sh already run (or Ambient deployed + session created)
#   - oc login to the cluster
#   - Node.js >= 18, npm, podman or docker

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${BOLD}${BLUE}[launcher]${RESET} $*"; }
warn() { echo -e "${BOLD}${YELLOW}[launcher]${RESET} $*"; }
err()  { echo -e "${BOLD}${RED}[launcher]${RESET} $*" >&2; }

# ── Configuration ────────────────────────────────────────────────────
AMBIENT_NAMESPACE="${AMBIENT_NAMESPACE:-ambient-code}"
AMBIENT_BACKEND_LOCAL_PORT="${AMBIENT_BACKEND_LOCAL_PORT:-8443}"
ADAPTER_PORT="${ADAPTER_PORT:-8080}"
PLUGIN_PORT="${PLUGIN_PORT:-9001}"
CONSOLE_PORT="${CONSOLE_PORT:-9000}"

AMBIENT_PROJECT="${AMBIENT_PROJECT:-default}"
AMBIENT_SESSION="${AMBIENT_SESSION:-}"
AMBIENT_API_URL="${AMBIENT_API_URL:-}"
AMBIENT_TOKEN="${AMBIENT_TOKEN:-}"
MOCK_MODE="${MOCK_MODE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Auto-source .env.session if it exists and AMBIENT_SESSION is not set
if [ -z "$AMBIENT_SESSION" ] && [ "$MOCK_MODE" != "true" ] && [ -f "$SCRIPT_DIR/.env.session" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env.session"
    log "Loaded session config from .env.session"
fi

# ── Validation ───────────────────────────────────────────────────────
if [ "$MOCK_MODE" != "true" ] && [ -z "$AMBIENT_SESSION" ]; then
    log "No AMBIENT_SESSION set — adapter will auto-create sessions on first message."
fi

# ── Process tracking & cleanup ───────────────────────────────────────
PIDS=()

cleanup() {
    echo ""
    log "Shutting down..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
    log "All processes stopped."
}
trap cleanup EXIT INT TERM

# ── Step 1: Ambient backend ─────────────────────────────────────────
if [ "$MOCK_MODE" = "true" ]; then
    log "Running in ${YELLOW}MOCK MODE${RESET} — no backend needed."
elif [ -z "$AMBIENT_API_URL" ]; then
    # Try to auto-detect the backend via OpenShift Route first,
    # then fall back to kubectl port-forward.
    ROUTE_HOST=$(kubectl get route backend-api -n "$AMBIENT_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$ROUTE_HOST" ]; then
        AMBIENT_API_URL="https://${ROUTE_HOST}"
        export NODE_TLS_REJECT_UNAUTHORIZED=0
        log "Using Ambient backend Route: ${AMBIENT_API_URL}"
    else
        log "Port-forwarding Ambient backend (${AMBIENT_NAMESPACE}/backend-service → localhost:${AMBIENT_BACKEND_LOCAL_PORT})..."

        if ! kubectl get svc backend-service -n "$AMBIENT_NAMESPACE" &>/dev/null; then
            err "Cannot find backend-service in namespace ${AMBIENT_NAMESPACE}."
            err "Deploy Ambient first, or use MOCK_MODE=true for a demo."
            exit 1
        fi

        kubectl port-forward -n "$AMBIENT_NAMESPACE" svc/backend-service "${AMBIENT_BACKEND_LOCAL_PORT}:8080" &>/dev/null &
        PIDS+=($!)
        sleep 1

        if ! kill -0 "${PIDS[-1]}" 2>/dev/null; then
            err "Port-forward failed. Is port ${AMBIENT_BACKEND_LOCAL_PORT} already in use?"
            exit 1
        fi

        AMBIENT_API_URL="http://localhost:${AMBIENT_BACKEND_LOCAL_PORT}"
    fi

    if [ -z "$AMBIENT_TOKEN" ]; then
        # Try OC token first, then fall back to test-user SA token
        AMBIENT_TOKEN=$(oc whoami -t 2>/dev/null || true)
        if [ -z "$AMBIENT_TOKEN" ]; then
            AMBIENT_TOKEN=$(kubectl get secret test-user-token -n "$AMBIENT_NAMESPACE" \
                -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        if [ -n "$AMBIENT_TOKEN" ]; then
            log "Auto-detected auth token from cluster."
        else
            warn "Could not retrieve auth token. Requests may fail auth."
        fi
    fi

    log "Checking Ambient backend health..."
    for i in $(seq 1 10); do
        if curl -sf -k "${AMBIENT_API_URL}/health" >/dev/null 2>&1; then
            log "${GREEN}Ambient backend is healthy.${RESET}"
            break
        fi
        if [ "$i" -eq 10 ]; then
            err "Ambient backend not healthy after 10 attempts."
            exit 1
        fi
        sleep 1
    done
else
    log "Using existing Ambient backend at ${AMBIENT_API_URL}"
fi

# ── Step 2: Install adapter dependencies if needed ───────────────────
if [ ! -d "$SCRIPT_DIR/node_modules" ]; then
    log "Installing adapter dependencies..."
    (cd "$SCRIPT_DIR" && npm install --silent)
fi

# ── Step 3: Start the OLS→Ambient adapter ────────────────────────────
log "Starting OLS→Ambient adapter on port ${ADAPTER_PORT}..."

PORT="$ADAPTER_PORT" \
AMBIENT_API_URL="$AMBIENT_API_URL" \
AMBIENT_PROJECT="$AMBIENT_PROJECT" \
AMBIENT_SESSION="$AMBIENT_SESSION" \
AMBIENT_TOKEN="$AMBIENT_TOKEN" \
MOCK_MODE="$MOCK_MODE" \
    node "$SCRIPT_DIR/adapter.js" &
PIDS+=($!)
sleep 1

if ! kill -0 "${PIDS[-1]}" 2>/dev/null; then
    err "Adapter failed to start. Is port ${ADAPTER_PORT} already in use?"
    exit 1
fi

# ── Step 4: Start the lightspeed-console plugin dev server ───────────
log "Starting plugin dev server on port ${PLUGIN_PORT}..."
(cd "$REPO_DIR" && npm run start) &
PIDS+=($!)
sleep 2

# ── Step 5: Start the OpenShift console ──────────────────────────────
log "Starting OpenShift console on port ${CONSOLE_PORT}..."
echo ""
(cd "$REPO_DIR" && OLS_PORT="$ADAPTER_PORT" CONSOLE_PORT="$CONSOLE_PORT" ./start-console.sh) &
PIDS+=($!)

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  OLS-on-Ambient POC Stack${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${CYAN}Ambient backend${RESET}   ${AMBIENT_API_URL}"
echo -e "  ${CYAN}OLS adapter${RESET}       http://localhost:${ADAPTER_PORT}"
echo -e "  ${CYAN}Plugin server${RESET}     http://localhost:${PLUGIN_PORT}"
echo -e "  ${CYAN}Console UI${RESET}        ${GREEN}http://localhost:${CONSOLE_PORT}${RESET}"
echo -e ""
echo -e "  ${CYAN}Project${RESET}           ${AMBIENT_PROJECT}"
echo -e "  ${CYAN}Session${RESET}           ${AMBIENT_SESSION}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Open ${GREEN}http://localhost:${CONSOLE_PORT}${RESET} and use the Lightspeed chat."
echo -e "  Press ${YELLOW}Ctrl+C${RESET} to stop everything."
echo ""

# Wait for all background processes
wait
