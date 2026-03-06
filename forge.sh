#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# fabric-forge -- one script to forge the fabric
# Provisions a k3s cluster and deploys the Fabric-SDK runtime via Helm charts.
# Inspired by StackForge's guided bootstrap and git-steer's file-based patterns.
# ──────────────────────────────────────────────────────────────────────────────

FORGE_VERSION="0.1.0"
FORGE_DIR="$HOME/.fabric-forge"
KUBECONFIG_PATH="$FORGE_DIR/kubeconfig"
STATE_FILE="$FORGE_DIR/state.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[forge]${NC} $1"; }
warn() { echo -e "${YELLOW}[forge]${NC} $1"; }
err()  { echo -e "${RED}[forge]${NC} $1" >&2; }
bold() { echo -e "${BOLD}$1${NC}"; }

# ── Banner ────────────────────────────────────────────────────────────────────

banner() {
  echo -e "${CYAN}"
  cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║                                                           ║
  ║   FABRIC-FORGE                                            ║
  ║   Forge the fabric. One script, full stack.               ║
  ║                                                           ║
  ║   k3s + Ollama + Tailscale + AIANA + Gateway              ║
  ║                                                           ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
  echo -e "${NC}"
  echo "  Version: $FORGE_VERSION"
  echo ""
}

# ── Prereq checks ────────────────────────────────────────────────────────────

check_prereqs() {
  local missing=()

  command -v curl  >/dev/null 2>&1 || missing+=("curl")
  command -v helm  >/dev/null 2>&1 || missing+=("helm")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")

  if [ ${#missing[@]} -gt 0 ]; then
    err "Missing required tools: ${missing[*]}"
    echo ""
    echo "Install them:"
    for tool in "${missing[@]}"; do
      case "$tool" in
        curl)    echo "  apt install curl / brew install curl" ;;
        helm)    echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ;;
        kubectl) echo "  curl -LO https://dl.k8s.io/release/stable.txt && curl -LO \"https://dl.k8s.io/release/\$(cat stable.txt)/bin/\$(uname -s | tr A-Z a-z)/\$(uname -m)/kubectl\" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/" ;;
      esac
    done
    exit 1
  fi

  log "Prerequisites: curl, helm, kubectl -- all present"
}

# ── State management ──────────────────────────────────────────────────────────

init_state() {
  mkdir -p "$FORGE_DIR"

  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" << EOF
# fabric-forge state -- generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
FORGE_VERSION=$FORGE_VERSION
CLUSTER_CREATED=false
OLLAMA_DEPLOYED=false
REDIS_DEPLOYED=false
AIANA_DEPLOYED=false
GATEWAY_DEPLOYED=false
DASHBOARD_DEPLOYED=false
TAILSCALE_DEPLOYED=false
EOF
    log "State file created: $STATE_FILE"
  fi

  source "$STATE_FILE"
}

save_state() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"
  else
    echo "${key}=${value}" >> "$STATE_FILE"
  fi
}

# ── k3s cluster ───────────────────────────────────────────────────────────────

install_k3s() {
  if [ "${CLUSTER_CREATED:-false}" = "true" ] && [ -f "$KUBECONFIG_PATH" ]; then
    log "k3s cluster already provisioned -- skipping"
    export KUBECONFIG="$KUBECONFIG_PATH"
    return
  fi

  bold "Phase 1: k3s Cluster"
  echo ""

  # Detect environment
  if [ "$(uname)" = "Darwin" ]; then
    # macOS -- use k3d
    if ! command -v docker >/dev/null 2>&1; then
      err "Docker is required on macOS. Install Docker Desktop first."
      exit 1
    fi

    if ! command -v k3d >/dev/null 2>&1; then
      log "Installing k3d..."
      curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    fi

    log "Creating k3d cluster: fabric-forge"
    k3d cluster create fabric-forge \
      --servers 1 \
      --agents 1 \
      --port "8100:8100@loadbalancer" \
      --port "7340:7340@loadbalancer" \
      --port "11434:11434@loadbalancer" \
      --port "32500:32500@loadbalancer" \
      --k3s-arg "--disable=traefik@server:0" \
      --wait

    k3d kubeconfig get fabric-forge > "$KUBECONFIG_PATH"
  else
    # Linux -- bare metal k3s
    log "Installing k3s (bare metal)..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -

    # Wait for k3s to be ready
    local retries=30
    while [ $retries -gt 0 ]; do
      if sudo k3s kubectl get nodes >/dev/null 2>&1; then
        break
      fi
      sleep 2
      retries=$((retries - 1))
    done

    sudo cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
    sudo chown "$(id -u):$(id -g)" "$KUBECONFIG_PATH"
  fi

  export KUBECONFIG="$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"

  # Verify
  if kubectl get nodes >/dev/null 2>&1; then
    log "Cluster ready:"
    kubectl get nodes -o wide
    echo ""
    save_state "CLUSTER_CREATED" "true"
  else
    err "Cluster creation failed"
    exit 1
  fi
}

# ── Namespace ─────────────────────────────────────────────────────────────────

create_namespace() {
  kubectl create namespace fabric-sdk --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  log "Namespace: fabric-sdk"
}

# ── Helm chart deployments ────────────────────────────────────────────────────

deploy_ollama() {
  if [ "${OLLAMA_DEPLOYED:-false}" = "true" ]; then
    log "Ollama already deployed -- skipping"
    return
  fi

  bold "Phase 2: Ollama (Local LLM)"
  echo ""

  helm upgrade --install ollama "$SCRIPT_DIR/charts/ollama" \
    --namespace fabric-sdk \
    --wait --timeout 300s

  log "Ollama deployed -- pulling default model..."
  # Model pull happens via init container in the chart

  save_state "OLLAMA_DEPLOYED" "true"
}

deploy_redis() {
  if [ "${REDIS_DEPLOYED:-false}" = "true" ]; then
    log "Redis already deployed -- skipping"
    return
  fi

  bold "Phase 3: Redis (Route Cache)"
  echo ""

  helm upgrade --install redis "$SCRIPT_DIR/charts/redis" \
    --namespace fabric-sdk \
    --wait --timeout 120s

  save_state "REDIS_DEPLOYED" "true"
}

deploy_aiana() {
  if [ "${AIANA_DEPLOYED:-false}" = "true" ]; then
    log "AIANA already deployed -- skipping"
    return
  fi

  bold "Phase 4: fabric-aiana (Semantic Memory)"
  echo ""

  # Check for required secrets
  if ! kubectl get secret aiana-secrets -n fabric-sdk >/dev/null 2>&1; then
    warn "Secret 'aiana-secrets' not found in fabric-sdk namespace."
    echo ""
    echo "  Create it with your Qdrant and OpenAI credentials:"
    echo ""
    echo "  kubectl create secret generic aiana-secrets -n fabric-sdk \\"
    echo "    --from-literal=QDRANT_URL=https://your-instance.qdrant.io:6333 \\"
    echo "    --from-literal=QDRANT_API_KEY=your-qdrant-key \\"
    echo "    --from-literal=OPENAI_API_KEY=your-openai-key"
    echo ""
    read -p "  Press Enter after creating the secret (or Ctrl+C to abort)... "

    if ! kubectl get secret aiana-secrets -n fabric-sdk >/dev/null 2>&1; then
      err "Secret still not found. Aborting AIANA deployment."
      return
    fi
  fi

  helm upgrade --install fabric-aiana "$SCRIPT_DIR/charts/fabric-aiana" \
    --namespace fabric-sdk \
    --wait --timeout 120s

  save_state "AIANA_DEPLOYED" "true"
}

deploy_gateway() {
  if [ "${GATEWAY_DEPLOYED:-false}" = "true" ]; then
    log "Gateway already deployed -- skipping"
    return
  fi

  bold "Phase 5: fabric-gateway (Route Reflector)"
  echo ""

  helm upgrade --install fabric-gateway "$SCRIPT_DIR/charts/fabric-gateway" \
    --namespace fabric-sdk \
    --wait --timeout 120s

  save_state "GATEWAY_DEPLOYED" "true"
}

deploy_dashboard() {
  if [ "${DASHBOARD_DEPLOYED:-false}" = "true" ]; then
    log "Dashboard already deployed -- skipping"
    return
  fi

  bold "Phase 6: Dashboard (Control Plane)"
  echo ""

  helm upgrade --install fabric-dashboard "$SCRIPT_DIR/charts/dashboard" \
    --namespace fabric-sdk \
    --wait --timeout 60s

  log "Dashboard available at http://localhost:32500"
  save_state "DASHBOARD_DEPLOYED" "true"
}

# ── Status ────────────────────────────────────────────────────────────────────

show_status() {
  echo ""
  bold "═══ Fabric-Forge Status ═══"
  echo ""

  export KUBECONFIG="$KUBECONFIG_PATH"

  echo "Pods:"
  kubectl get pods -n fabric-sdk -o wide 2>/dev/null || echo "  (no pods)"
  echo ""

  echo "Services:"
  kubectl get svc -n fabric-sdk 2>/dev/null || echo "  (no services)"
  echo ""

  echo "Endpoints:"
  echo "  Dashboard:  http://localhost:32500"
  echo "  Ollama:     http://localhost:11434"
  echo "  Gateway:    http://localhost:7340"
  echo "  AIANA:      http://localhost:8100"
  echo "  Redis:      redis://localhost:6379 (cluster-internal)"
  echo ""
  echo "Kubeconfig:   $KUBECONFIG_PATH"
  echo "State:        $STATE_FILE"
}

# ── Destroy ───────────────────────────────────────────────────────────────────

destroy() {
  warn "This will destroy the fabric-forge cluster and all data."
  read -p "Are you sure? (y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log "Aborted."
    return
  fi

  if [ "$(uname)" = "Darwin" ]; then
    k3d cluster delete fabric-forge 2>/dev/null || true
  else
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
  fi

  rm -rf "$FORGE_DIR"
  log "Cluster and state destroyed."
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  banner

  case "${1:-}" in
    --destroy)
      destroy
      exit 0
      ;;
    --status)
      init_state
      show_status
      exit 0
      ;;
    --kubeconfig)
      echo "$KUBECONFIG_PATH"
      exit 0
      ;;
    --help|-h)
      echo "Usage: bash forge.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  (none)        Full guided install"
      echo "  --status      Show cluster and pod status"
      echo "  --destroy     Tear down cluster and state"
      echo "  --kubeconfig  Print kubeconfig path"
      echo "  --help        Show this help"
      exit 0
      ;;
  esac

  check_prereqs
  init_state
  install_k3s
  create_namespace
  deploy_ollama
  deploy_redis
  deploy_gateway
  deploy_aiana
  deploy_dashboard
  show_status

  echo ""
  bold "Fabric forged."
  echo ""
}

main "$@"
