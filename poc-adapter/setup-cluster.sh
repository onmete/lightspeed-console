#!/usr/bin/env bash
#
# Deploys the Ambient Code Platform and supporting services to an OpenShift
# cluster, creates a project + session, and prints the session name for use
# with start-all.sh.
#
# Prerequisites:
#   - oc login to a ROSA/OSD/OCP cluster with cluster-admin
#   - kubectl available (same context)
#   - Ambient platform repo at ~/projects/ambient (configurable via AMBIENT_REPO)
#   - GCP Vertex AI credentials at ~/.config/gcloud/application_default_credentials.json
#     (or set USE_VERTEX=0 and provide ANTHROPIC_API_KEY)
#
# Usage:
#   ./setup-cluster.sh
#
# Outputs a file .env.session that start-all.sh can source.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${BOLD}${BLUE}[setup]${RESET} $*"; }
warn() { echo -e "${BOLD}${YELLOW}[setup]${RESET} $*"; }
err()  { echo -e "${BOLD}${RED}[setup]${RESET} $*" >&2; }
ok()   { echo -e "${BOLD}${GREEN}  ✓${RESET} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMBIENT_REPO="${AMBIENT_REPO:-$HOME/projects/ambient}"
AMBIENT_NAMESPACE="ambient-code"
PROJECT_NAME="${AMBIENT_PROJECT:-poc-test}"

# ── Preflight checks ─────────────────────────────────────────────────
log "Preflight checks..."

if ! oc whoami &>/dev/null; then
    err "Not logged in to OpenShift. Run: oc login <cluster>"
    exit 1
fi
ok "oc login: $(oc whoami) @ $(oc whoami --show-server 2>/dev/null || echo 'unknown')"

if [ ! -d "$AMBIENT_REPO/platform/components/manifests" ]; then
    err "Ambient repo not found at $AMBIENT_REPO"
    err "Set AMBIENT_REPO=/path/to/ambient"
    exit 1
fi
ok "Ambient repo: $AMBIENT_REPO"

OC_TOKEN=$(oc whoami -t)

# ── Step 1: Deploy Ambient stack ──────────────────────────────────────
log "Step 1/8: Deploying Ambient stack to namespace ${AMBIENT_NAMESPACE}..."

kubectl create namespace "$AMBIENT_NAMESPACE" 2>/dev/null && ok "Created namespace $AMBIENT_NAMESPACE" || ok "Namespace $AMBIENT_NAMESPACE exists"

kubectl apply -k "$AMBIENT_REPO/platform/components/manifests/overlays/kind" 2>&1 | tail -5
ok "Ambient manifests applied"

# ── Step 2: Fix OpenShift-specific issues ─────────────────────────────
log "Step 2/8: Fixing OpenShift PVCs and SCCs..."

DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
if [ -z "$DEFAULT_SC" ]; then
    DEFAULT_SC="gp3-csi"
fi

for PVC_NAME in backend-state-pvc minio-data postgresql-data ambient-api-server-db-data; do
    CURRENT_SC=$(kubectl get pvc "$PVC_NAME" -n "$AMBIENT_NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
    if [ "$CURRENT_SC" != "$DEFAULT_SC" ] && [ -n "$CURRENT_SC" ]; then
        kubectl delete pvc "$PVC_NAME" -n "$AMBIENT_NAMESPACE" --force --grace-period=0 2>/dev/null || true
        cat <<PVCEOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $AMBIENT_NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $DEFAULT_SC
  resources:
    requests:
      storage: 5Gi
PVCEOF
    fi
done
ok "PVCs use storageClass $DEFAULT_SC"

oc adm policy add-scc-to-user anyuid -z default -n "$AMBIENT_NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z agentic-operator -n "$AMBIENT_NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z backend-api -n "$AMBIENT_NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z ambient-api-server -n "$AMBIENT_NAMESPACE" 2>/dev/null || true
ok "SCCs granted"

# Fix backend PVC permissions (OpenShift UID range)
UID_RANGE=$(kubectl get namespace "$AMBIENT_NAMESPACE" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' 2>/dev/null | cut -d/ -f1)
if [ -n "$UID_RANGE" ]; then
    kubectl patch deployment backend-api -n "$AMBIENT_NAMESPACE" --type=merge \
        -p "{\"spec\":{\"template\":{\"spec\":{\"securityContext\":{\"fsGroup\":$UID_RANGE}}}}}" 2>/dev/null || true
    ok "Backend fsGroup set to $UID_RANGE"
fi

# ── Step 3: Configure LLM credentials (Vertex AI) ────────────────────
log "Step 3/8: Configuring LLM credentials..."

GCP_ADC="$HOME/.config/gcloud/application_default_credentials.json"
if [ -f "$GCP_ADC" ]; then
    kubectl create secret generic ambient-vertex -n "$AMBIENT_NAMESPACE" \
        --from-file=credentials.json="$GCP_ADC" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    kubectl patch configmap operator-config -n "$AMBIENT_NAMESPACE" --type merge -p '{
        "data": {
            "USE_VERTEX": "1",
            "CLOUD_ML_REGION": "'"${CLOUD_ML_REGION:-us-east5}"'",
            "ANTHROPIC_VERTEX_PROJECT_ID": "'"${ANTHROPIC_VERTEX_PROJECT_ID:-}"'",
            "GOOGLE_APPLICATION_CREDENTIALS": "/app/vertex/credentials.json"
        }
    }' 2>/dev/null
    kubectl set env deployment/backend-api -n "$AMBIENT_NAMESPACE" \
        USE_VERTEX=1 \
        CLOUD_ML_REGION="${CLOUD_ML_REGION:-us-east5}" \
        ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-}" \
        GOOGLE_APPLICATION_CREDENTIALS=/app/vertex/credentials.json 2>/dev/null
    kubectl set env deployment/agentic-operator -n "$AMBIENT_NAMESPACE" \
        USE_VERTEX=1 \
        CLOUD_ML_REGION="${CLOUD_ML_REGION:-us-east5}" \
        ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-}" \
        GOOGLE_APPLICATION_CREDENTIALS=/app/vertex/credentials.json 2>/dev/null
    ok "Vertex AI configured (region: ${CLOUD_ML_REGION:-us-east5})"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "Using ANTHROPIC_API_KEY (Vertex disabled)"
else
    warn "No GCP ADC found and ANTHROPIC_API_KEY not set. Sessions may fail."
fi

# ── Step 4: Create MinIO bucket ───────────────────────────────────────
log "Step 4/8: Ensuring MinIO bucket exists..."

kubectl run -n "$AMBIENT_NAMESPACE" mc-setup --rm -i --restart=Never \
    --image=minio/mc:latest \
    --env="MC_HOST_myminio=http://minioadmin:minioadmin123@minio.${AMBIENT_NAMESPACE}.svc:9000" \
    --command -- mc mb --ignore-existing myminio/ambient-sessions 2>&1 | grep -v "^$" || true
ok "MinIO bucket ambient-sessions ready"

# ── Step 5: Create OpenShift Route for backend ────────────────────────
log "Step 5/8: Creating backend Route..."

kubectl apply -f - <<'ROUTEEOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: backend-api
  namespace: ambient-code
spec:
  to:
    kind: Service
    name: backend-service
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
ROUTEEOF
ok "Route created"

# ── Step 6: Deploy Kubernetes MCP server ──────────────────────────────
log "Step 6/8: Deploying Kubernetes MCP server..."

kubectl apply -f - <<'K8SMCPEOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubernetes-mcp-server
  namespace: ambient-code
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-mcp-server-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-reader
subjects:
- kind: ServiceAccount
  name: kubernetes-mcp-server
  namespace: ambient-code
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-mcp-server
  namespace: ambient-code
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kubernetes-mcp-server
  template:
    metadata:
      labels:
        app: kubernetes-mcp-server
    spec:
      serviceAccountName: kubernetes-mcp-server
      containers:
      - name: mcp-server
        image: quay.io/containers/kubernetes_mcp_server:latest
        args: ["--port", "8008", "--read-only", "--cluster-provider", "in-cluster"]
        ports:
        - containerPort: 8008
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-mcp-server
  namespace: ambient-code
spec:
  selector:
    app: kubernetes-mcp-server
  ports:
  - port: 8008
    targetPort: 8008
    name: http
K8SMCPEOF
ok "Kubernetes MCP server deployed"

# Configure operator to use custom MCP config that includes the K8s MCP server
kubectl set env deployment/agentic-operator -n "$AMBIENT_NAMESPACE" \
    MCP_CONFIG_FILE=/workspace/.mcp.json 2>/dev/null
ok "Operator configured for custom MCP"

# ── Step 7: Wait for core pods ────────────────────────────────────────
log "Step 7/8: Waiting for core pods to be ready..."

kubectl rollout restart deployment backend-api minio postgresql agentic-operator -n "$AMBIENT_NAMESPACE" 2>/dev/null || true

for DEPLOY in backend-api agentic-operator minio postgresql; do
    kubectl rollout status deployment/"$DEPLOY" -n "$AMBIENT_NAMESPACE" --timeout=120s 2>/dev/null && ok "$DEPLOY ready" || warn "$DEPLOY may not be ready"
done

# ── Step 8: Create project and session ────────────────────────────────
log "Step 8/8: Creating project and session..."

ROUTE_HOST=$(kubectl get route backend-api -n "$AMBIENT_NAMESPACE" -o jsonpath='{.spec.host}')
API_URL="https://${ROUTE_HOST}"

# Wait for backend health via Route
for i in $(seq 1 20); do
    if curl -sf -k "${API_URL}/health" >/dev/null 2>&1; then break; fi
    sleep 3
done

# Create project
curl -sf -k -X POST "${API_URL}/api/projects" \
    -H "X-Forwarded-Access-Token: $OC_TOKEN" \
    -H "X-Forwarded-User: cluster-admin" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$PROJECT_NAME\"}" >/dev/null 2>&1 || true
ok "Project $PROJECT_NAME ready"

# Grant anyuid to project SA (for runner pods)
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:$PROJECT_NAME" 2>/dev/null || true

# Create runner secrets (Vertex mode)
kubectl create secret generic ambient-runner-secrets -n "$PROJECT_NAME" \
    --from-literal=USE_VERTEX=1 --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# Create session
RESULT=$(curl -sf -k -X POST "${API_URL}/api/projects/${PROJECT_NAME}/agentic-sessions" \
    -H "X-Forwarded-Access-Token: $OC_TOKEN" \
    -H "X-Forwarded-User: cluster-admin" \
    -H "Content-Type: application/json" \
    -d '{"displayName":"ols-poc"}' 2>&1)
SESSION_NAME=$(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin)['name'])" 2>/dev/null)
ok "Session created: $SESSION_NAME"

# Wait for session to be Running
log "Waiting for runner pod..."
for i in $(seq 1 60); do
    PHASE=$(kubectl get agenticsession "$SESSION_NAME" -n "$PROJECT_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$PHASE" = "Running" ]; then
        ok "Session is Running"
        break
    fi
    if [ "$PHASE" = "Failed" ]; then
        err "Session failed. Check: kubectl logs deployment/agentic-operator -n $AMBIENT_NAMESPACE --tail=20"
        exit 1
    fi
    sleep 3
done

# Write MCP config to the runner workspace
RUNNER_POD="${SESSION_NAME}-runner"
kubectl exec "$RUNNER_POD" -n "$PROJECT_NAME" -c ambient-code-runner -- sh -c 'cat > /workspace/.mcp.json << '"'"'MCPJSON'"'"'
{
  "mcpServers": {
    "kubernetes": {
      "type": "http",
      "url": "http://kubernetes-mcp-server.ambient-code.svc:8008/mcp"
    },
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp"
    },
    "deepwiki": {
      "type": "http",
      "url": "https://mcp.deepwiki.com/mcp"
    },
    "webfetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    }
  }
}
MCPJSON' 2>/dev/null
ok "MCP config written to runner workspace"

# ── Write env file for start-all.sh ──────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env.session"
cat > "$ENV_FILE" <<ENVEOF
# Generated by setup-cluster.sh at $(date -Iseconds)
export AMBIENT_PROJECT="$PROJECT_NAME"
export AMBIENT_SESSION="$SESSION_NAME"
ENVEOF
ok "Saved session config to $ENV_FILE"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Cluster Setup Complete${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Project:    ${GREEN}$PROJECT_NAME${RESET}"
echo -e "  Session:    ${GREEN}$SESSION_NAME${RESET}"
echo -e "  Backend:    ${GREEN}$API_URL${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Next: start the local UI stack:"
echo -e "    ${BOLD}source $ENV_FILE && ./start-all.sh${RESET}"
echo ""
