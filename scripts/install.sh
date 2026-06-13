#!/usr/bin/env bash
# =============================================================================
# install.sh — AMD Enterprise AI Reference Stack Installer
# BNY MI355X POC | Idempotent Installation Script
#
# Usage:
#   ./scripts/install.sh              Normal install (skips completed phases)
#   FORCE_REDEPLOY=true ./scripts/install.sh   Force full reinstall
#
# Required: .env file with DOCKERHUB_USER and DOCKERHUB_TOKEN
# Docs: https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html
# =============================================================================
set -euo pipefail

# --- Color Helpers ---
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

_log()  { echo -e "[$(date +'%F %T')] $*"; }
log()   { _log "${CYAN}[INFO]${RESET}  $*"; }
warn()  { _log "${YELLOW}[WARN]${RESET}  $*"; }
error() { _log "${RED}[ERROR]${RESET} $*"; }
ok()    { _log "${GREEN}[ OK ]${RESET}  $*"; }
run()   { log "RUN: $*"; "$@"; }
header() {
  echo ""
  echo -e "${BOLD}$*${RESET}"
}

# =============================================================================
# Load .env
# =============================================================================
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  log "Loaded environment from: $ENV_FILE"
else
  warn ".env file not found at $ENV_FILE"
  warn "Docker Hub rate limits may cause ImagePullBackOff errors."
  warn "Create .env with DOCKERHUB_USER and DOCKERHUB_TOKEN to avoid this."
fi

# =============================================================================
# Configuration (overridable via .env)
# =============================================================================
WORKDIR="${WORKDIR:-$PWD/amd-enterprise-ai-install}"
STATE_DIR="${STATE_DIR:-$WORKDIR/.state}"
LOG_DIR="${LOG_DIR:-$WORKDIR/logs}"

BLOOM_VERSION="${BLOOM_VERSION:-v1.2.2}"
FORGE_VERSION="${FORGE_VERSION:-v1.5.2}"
BLOOM_URL="${BLOOM_URL:-https://github.com/silogen/cluster-bloom/releases/download/${BLOOM_VERSION}/bloom}"
FORGE_URL="${FORGE_URL:-https://github.com/silogen/cluster-forge/releases/download/${FORGE_VERSION}/release-enterprise-ai-${FORGE_VERSION}.tar.gz}"

DOMAIN_OVERRIDE="${DOMAIN_OVERRIDE:-}"
IP_OVERRIDE="${IP_OVERRIDE:-}"
DISK_OVERRIDE="${DISK_OVERRIDE:-}"
CERT_OPTION="${CERT_OPTION:-generate}"
# When CERT_OPTION=existing, cluster-bloom requires both a certificate
# (full chain) and its matching private key.
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
FIRST_NODE="${FIRST_NODE:-true}"
GPU_NODE="${GPU_NODE:-true}"
USE_CERT_MANAGER="${USE_CERT_MANAGER:-false}"
CLUSTERFORGE_RELEASE="${CLUSTERFORGE_RELEASE:-none}"
ENABLE_HTTPROUTE="${ENABLE_HTTPROUTE:-false}"
DEBUG_MODE="${DEBUG_MODE:-true}"
FORCE_REDEPLOY="${FORCE_REDEPLOY:-false}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"

# Minimum GPU count check (MI355X POC = 8 GPUs)
MIN_GPU_COUNT="${MIN_GPU_COUNT:-1}"

mkdir -p "$WORKDIR" "$STATE_DIR" "$LOG_DIR"
cd "$WORKDIR"

# =============================================================================
# State Management
# =============================================================================
mark_done() { touch "$STATE_DIR/$1.done"; }
is_done()   { [[ -f "$STATE_DIR/$1.done" ]]; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

kubectl_ready() {
  have_cmd kubectl && kubectl get nodes >/dev/null 2>&1
}

# =============================================================================
# Network / Disk Detection
# =============================================================================
get_primary_ip() {
  if [[ -n "$IP_OVERRIDE" ]]; then echo "$IP_OVERRIDE"; return; fi
  ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true
}

pick_disk() {
  if [[ -n "$DISK_OVERRIDE" ]]; then echo "$DISK_OVERRIDE"; return; fi
  lsblk -dn -o NAME,TYPE,MOUNTPOINTS 2>/dev/null \
    | awk '$2=="disk" && $3=="" && $1 ~ /^nvme/ {print "/dev/"$1; exit}'
}

validate_disk() {
  local disk="$1"
  [[ -b "$disk" ]] || { error "Disk does not exist: $disk"; exit 1; }
  if lsblk -no MOUNTPOINT "$disk" | grep -q .; then
    error "Disk is mounted or in use: $disk"
    lsblk "$disk" || true
    exit 1
  fi
  log "Selected disk: $disk"
  sudo wipefs -n "$disk" || true
}

# =============================================================================
# GPU Validation (MI355X POC)
# =============================================================================
validate_gpus() {
  header "GPU Pre-flight Check"
  local gpu_count=0

  # Try rocm-smi first
  if have_cmd rocm-smi; then
    gpu_count=$(rocm-smi --showid 2>/dev/null | grep -c "GPU\[") || gpu_count=0
    ok "rocm-smi detected ${gpu_count} GPU(s)"
    rocm-smi --showproductname 2>/dev/null | grep -E "GPU|gfx|MI" || true
  fi

  # Try lspci fallback
  if [[ "$gpu_count" -eq 0 ]] && have_cmd lspci; then
    gpu_count=$(lspci 2>/dev/null | grep -ci "AMD\|Radeon\|Instinct") || gpu_count=0
    log "lspci detected ~${gpu_count} AMD device(s)"
  fi

  if [[ "$gpu_count" -lt "$MIN_GPU_COUNT" ]]; then
    warn "Expected at least ${MIN_GPU_COUNT} GPU(s), detected ${gpu_count}."
    warn "Continuing anyway — ROCm drivers may not be installed yet."
  else
    ok "GPU check passed: ${gpu_count} GPU(s) detected."
  fi
}

# =============================================================================
# HTTPRoute Skip File
# =============================================================================
prepare_httproute_skip() {
  local skip_file="/var/lib/rancher/rke2/server/manifests/httproute-longhorn.yaml.skip"
  if [[ "$ENABLE_HTTPROUTE" == "true" ]]; then
    sudo rm -f "$skip_file" 2>/dev/null || true
    log "HTTPRoute enabled; skip file removed if present."
  else
    sudo mkdir -p /var/lib/rancher/rke2/server/manifests
    echo "disabled by scripts/install.sh for POC stability" \
      | sudo tee "$skip_file" >/dev/null
    log "Applied RKE2 skip file: $skip_file"
  fi
}

# =============================================================================
# Downloads
# =============================================================================
download_release() {
  local tarball="$WORKDIR/release-enterprise-ai.tar.gz"
  local extract_dir="$WORKDIR/enterprise-ai-${FORGE_VERSION}"

  if [[ -f "$tarball" && "$FORCE_REDEPLOY" != "true" ]]; then
    log "Enterprise AI release already present; skipping download."
  else
    log "Downloading Cluster-Forge ${FORGE_VERSION}..."
    run curl -fsSL --progress-bar -o "$tarball" "$FORGE_URL"
    ok "Cluster-Forge downloaded."
  fi

  if [[ ! -d "$extract_dir" ]]; then
    log "Extracting Enterprise AI release..."
    run tar -xzf "$tarball" -C "$WORKDIR"
    ok "Extracted to: $extract_dir"
  fi
}

download_bloom() {
  local bloom_bin="$WORKDIR/bloom"

  if [[ -x "$bloom_bin" && "$FORCE_REDEPLOY" != "true" ]]; then
    log "Bloom binary already present; skipping download."
  else
    log "Downloading Bloom ${BLOOM_VERSION}..."
    run curl -fsSL --progress-bar -o "$bloom_bin" "$BLOOM_URL"
    chmod +x "$bloom_bin"
    ok "Bloom downloaded."
  fi

  local ft arch
  ft="$(file "$bloom_bin" || true)"
  arch="$(uname -m)"
  log "Host arch: $arch | Bloom: $ft"

  if ! echo "$ft" | grep -Eq 'ELF .*x86-64|ELF .*aarch64|ELF .*ARM'; then
    error "Bloom binary is not a runnable ELF: $ft"
    exit 1
  fi
}

# =============================================================================
# bloom.yaml Generation
# =============================================================================
write_bloom_yaml() {
  local domain="$1"
  local disk="$2"

  cat >"$WORKDIR/bloom.yaml" <<EOF
DOMAIN: ${domain}
CERT_OPTION: ${CERT_OPTION}
FIRST_NODE: ${FIRST_NODE}
GPU_NODE: ${GPU_NODE}
USE_CERT_MANAGER: ${USE_CERT_MANAGER}
CLUSTER_DISKS: ${disk}
OIDC_URL: https://kc.${domain}/realms/airm
CLUSTERFORGE_RELEASE: ${CLUSTERFORGE_RELEASE}
EOF

  if [[ "$CERT_OPTION" == "existing" ]]; then
    if [[ -z "$TLS_CERT" || -z "$TLS_KEY" ]]; then
      error "CERT_OPTION=existing requires both TLS_CERT and TLS_KEY to be set (in .env or env)."
      exit 1
    fi
    [[ -f "$TLS_CERT" ]] || { error "TLS_CERT file not found: $TLS_CERT"; exit 1; }
    [[ -f "$TLS_KEY"  ]] || { error "TLS_KEY file not found: $TLS_KEY"; exit 1; }
    cat >>"$WORKDIR/bloom.yaml" <<EOF
TLS_CERT: ${TLS_CERT}
TLS_KEY: ${TLS_KEY}
EOF
    ok "Using existing TLS certificate: ${TLS_CERT}"
  fi

  if [[ -n "$DOCKERHUB_USER" && -n "$DOCKERHUB_TOKEN" ]]; then
    cat >>"$WORKDIR/bloom.yaml" <<EOF
DOCKERHUB_USER: ${DOCKERHUB_USER}
DOCKERHUB_TOKEN: ${DOCKERHUB_TOKEN}
EOF
    ok "Docker Hub credentials added to bloom.yaml"
  else
    warn "DOCKERHUB_USER/DOCKERHUB_TOKEN not set — Docker Hub rate limits may apply."
  fi
}

# =============================================================================
# Debug Snapshot
# =============================================================================
snapshot_debug() {
  mkdir -p "$LOG_DIR/debug"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  # Redact secrets before copying bloom.yaml into the debug snapshot.
  sed -E 's/^(DOCKERHUB_TOKEN:).*/\1 [REDACTED]/' "$WORKDIR/bloom.yaml" \
    >"$LOG_DIR/debug/bloom.yaml.${ts}" 2>/dev/null || true

  {
    echo "=== uname ==="
    uname -a
    echo
    echo "=== lsblk ==="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    echo
    echo "=== blkid ==="
    sudo blkid || true
    echo
    echo "=== GPU (rocm-smi) ==="
    rocm-smi --showproductname 2>/dev/null || lspci | grep -i amd || echo "N/A"
    echo
    echo "=== kubectl crds (gateway) ==="
    kubectl get crd 2>/dev/null | grep gateway || true
  } >"$LOG_DIR/debug/preflight.${ts}.txt" 2>&1 || true

  log "Debug snapshot saved: $LOG_DIR/debug/preflight.${ts}.txt"
}

# =============================================================================
# Step: Bloom (K8s + ROCm + Storage)
# =============================================================================
step_bloom() {
  if is_done bloom && [[ "$FORCE_REDEPLOY" != "true" ]]; then
    log "Skipping Bloom install; already done. (delete $STATE_DIR/bloom.done to re-run)"
    return
  fi

  download_bloom
  local bloom_bin="$WORKDIR/bloom"

  header "Phase: Cluster-Bloom (RKE2 + ROCm + Longhorn)"
  log "Bloom CLI mode — non-interactive"
  log "Log: $LOG_DIR/bloom-install.log"

  sudo nohup "$bloom_bin" cli "$WORKDIR/bloom.yaml" \
    >"$LOG_DIR/bloom-install.log" 2>&1 &

  local pid=$!
  echo "$pid" >"$STATE_DIR/bloom.pid"
  log "Bloom PID: $pid"

  local last_line=""
  while kill -0 "$pid" 2>/dev/null; do
    local current; current=$(tail -n 1 "$LOG_DIR/bloom-install.log" 2>/dev/null || true)
    if [[ "$current" != "$last_line" && -n "$current" ]]; then
      log "bloom: $current"
      last_line="$current"
    fi
    sleep 15
  done

  wait "$pid" || {
    error "Bloom installer failed. Showing last 50 lines:"
    tail -n 50 "$LOG_DIR/bloom-install.log" || true
    exit 1
  }

  ok "Bloom install complete."
  mark_done bloom
}

# =============================================================================
# Step: Cluster-Forge (ArgoCD + OpenBao + Gitea)
# =============================================================================
step_deploy() {
  local domain="$1"

  if is_done deploy && [[ "$FORCE_REDEPLOY" != "true" ]]; then
    log "Skipping deploy; already done. (delete $STATE_DIR/deploy.done to re-run)"
    return
  fi

  header "Phase: Cluster-Forge (ArgoCD + OpenBao + Gitea)"

  # Find cluster-forge directory (name may include version)
  local forge_dir
  forge_dir=$(find "$WORKDIR" -maxdepth 1 -type d -name "cluster-forge*" | head -1 || true)

  if [[ -z "$forge_dir" ]]; then
    # Legacy path (older release structure)
    forge_dir="$WORKDIR/cluster-forge"
  fi

  if [[ -d "$forge_dir/scripts" ]]; then
    log "Running bootstrap from: $forge_dir/scripts"
    (
      cd "$forge_dir/scripts"
      bash ./bootstrap.sh "$domain"
    ) >"$LOG_DIR/deploy.log" 2>&1 || {
      error "Cluster-Forge bootstrap failed. Showing last 50 lines:"
      tail -n 50 "$LOG_DIR/deploy.log" || true
      exit 1
    }
    ok "Cluster-Forge deploy complete."
    mark_done deploy
  else
    warn "Cluster-Forge scripts directory not found at: $forge_dir/scripts"
    warn "Skipping deploy phase."
  fi
}

# =============================================================================
# Step: Verify
# =============================================================================
step_verify() {
  if is_done verify && [[ "$FORCE_REDEPLOY" != "true" ]]; then
    log "Skipping verify; already done."
    return
  fi

  header "Phase: Verification"

  if ! kubectl_ready; then
    warn "kubectl not ready yet. Skipping cluster checks."
    return
  fi

  log "--- Nodes ---"
  kubectl get nodes -o wide || true

  log "--- Pods (non-Completed) ---"
  kubectl get pods -A | grep -Ev "Completed" || true

  log "--- Recent Events ---"
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true

  log "--- Gateway Classes ---"
  kubectl get gatewayclass -A || true

  log "--- Gateways ---"
  kubectl get gateway -A || true

  log "--- HTTPRoutes ---"
  kubectl get httproute -A || true

  log "--- GPU Resources (amd.com/gpu) ---"
  kubectl get nodes -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.name): \(.status.allocatable["amd.com/gpu"] // "0") GPU(s)"' \
    || kubectl describe nodes | grep -A2 "Allocatable:" | grep gpu || true

  mark_done verify
  ok "Verification complete."
}

# =============================================================================
# Post-Install Summary
# =============================================================================
print_summary() {
  local domain="$1"

  header "Installation Complete!"
  echo ""
  echo -e "  ${BOLD}Web Interfaces:${RESET}"
  echo -e "  ┌─────────────────────────────────────────────────────────────────┐"
  echo -e "  │  AMD Resource Manager: ${GREEN}https://airmui.${domain}${RESET}"
  echo -e "  │  AMD AI Workbench:     ${GREEN}https://aiwbui.${domain}${RESET}"
  echo -e "  │  ArgoCD (GitOps):      ${GREEN}https://argocd.${domain}${RESET}"
  echo -e "  │  Gitea (Git):          ${GREEN}https://gitea.${domain}${RESET}"
  echo -e "  └─────────────────────────────────────────────────────────────────┘"
  echo ""
  echo -e "  ${BOLD}Default Login:${RESET}"
  echo -e "  Username: ${CYAN}devuser@${domain}${RESET}"
  echo -e "  Password: ${CYAN}password${RESET}  (forced change on first login)"
  echo ""
  echo -e "  ${BOLD}Next Steps (BNY POC):${RESET}"
  echo -e "  1. Add Hugging Face token in AI Workbench → Secrets"
  echo -e "  2. Deploy benchmark models: ${CYAN}kubectl apply -f scripts/bny-poc-models.yaml${RESET}"
  echo -e "  3. Monitor deployment: ${CYAN}./scripts/debug.sh --list${RESET}"
  echo -e "  4. See docs/QUICKSTART.md for full benchmark procedures"
  echo ""
  echo -e "  ${BOLD}Log Files:${RESET}"
  echo -e "  Bloom:  $LOG_DIR/bloom-install.log"
  echo -e "  Forge:  $LOG_DIR/deploy.log"
  echo -e "  Debug:  $LOG_DIR/debug/"
  echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
  header "AMD Enterprise AI Installer | BNY MI355X POC"
  log "WORKDIR: $WORKDIR"
  log "FORGE_VERSION: $FORGE_VERSION | BLOOM_VERSION: $BLOOM_VERSION"
  log "FORCE_REDEPLOY: $FORCE_REDEPLOY"

  # Pre-flight
  log "Running pre-flight checks..."
  run uname -a
  run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

  validate_gpus

  local ip domain disk
  ip="$(get_primary_ip)"
  domain="${DOMAIN_OVERRIDE:-${ip}.nip.io}"
  disk="$(pick_disk)"

  if [[ -z "$disk" ]]; then
    error "No suitable unmounted NVMe disk found."
    error "Set DISK_OVERRIDE=/dev/nvmeXn1 in your .env file."
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    exit 1
  fi

  log "Primary IP:  $ip"
  log "Domain:      $domain"
  log "Storage disk: $disk"
  log "HTTPRoute:   $ENABLE_HTTPROUTE"

  validate_disk "$disk"
  prepare_httproute_skip
  download_release
  write_bloom_yaml "$domain" "$disk"
  snapshot_debug

  log "Generated bloom.yaml:"
  sed 's/DOCKERHUB_TOKEN:.*/DOCKERHUB_TOKEN: [REDACTED]/' "$WORKDIR/bloom.yaml" \
    | sed 's/^/  /'

  step_bloom
  step_deploy "$domain"
  step_verify

  print_summary "$domain"
}

main "$@"