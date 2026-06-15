#!/usr/bin/env bash
# =============================================================================
# debug.sh — AMD Enterprise AI Diagnostics Tool
# AMD Enterprise AI | MI355X POC
#
# Aligned with: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html
#
# Usage:
#   ./scripts/debug.sh <service-name> [namespace]
#   ./scripts/debug.sh --list [namespace]
#   ./scripts/debug.sh --gpu
#   ./scripts/debug.sh --cluster
#   ./scripts/debug.sh --portal
#   ./scripts/debug.sh --endpoint [url]
#   ./scripts/debug.sh --help
#
# AIMService status values (from official docs):
#   Pending     — Waiting for upstream dependencies
#   Starting    — Creating downstream resources
#   Progressing — Resources created, waiting for readiness
#   Running     — Fully operational
#   Ready       — Resource is ready (non-service CRDs)
#   Degraded    — Partially functional
#   NotAvailable— Required infrastructure not present
#   Failed      — Critical failure
# =============================================================================
set -euo pipefail

# --- Color & Output Helpers ---
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*"; }
ok()     { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
fail()   { echo -e "${RED}[FAIL]${RESET}  $*"; }
dim()    { echo -e "${DIM}$*${RESET}"; }
bullet() { echo -e "  ${CYAN}•${RESET} $*"; }
indent() { sed 's/^/    /'; }
fix()    { echo -e "  ${YELLOW}↳ Fix:${RESET} $*"; }

header() {
  echo ""
  echo -e "${BOLD}$*${RESET}"
}

section() {
  echo ""
  echo -e "${BOLD}--- $* ---${RESET}"
}

# --- Prerequisite checks ---
HAS_JQ=false;   command -v jq   &>/dev/null && HAS_JQ=true
HAS_CURL=false; command -v curl &>/dev/null && HAS_CURL=true

# --- Helper: find AIM operator pod (supports aim-system, kaiwo-system, etc.) ---
find_aim_operator() {
  local pod="" ns=""
  # Official deployment: aim-system namespace, deployment/aim-engine-controller-manager
  pod=$(kubectl get pods -n aim-system \
    -l "control-plane=controller-manager" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$pod" ]]; then echo "aim-system/${pod}"; return; fi
  # Kaiwo / older installations
  pod=$(kubectl get pods -n kaiwo-system \
    -l "control-plane=kaiwo-controller-manager" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$pod" ]]; then echo "kaiwo-system/${pod}"; return; fi
  # Generic fallback
  local line
  line=$(kubectl get pods -A -l "app.kubernetes.io/component=controller" \
    --no-headers 2>/dev/null | grep -i "aim\|silogen\|kaiwo" | head -1 || true)
  if [[ -n "$line" ]]; then
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    echo "${ns}/${pod}"
    return
  fi
  echo "/"
}

# --- Helper: operator log streaming (JSON structured logs) ---
# Docs: filter by resource name using jq select(.name == "<resource>")
operator_logs_for() {
  local svc="$1" ns_pod="$2" tail="${3:-300}"
  local ns="${ns_pod%%/*}" pod="${ns_pod##*/}"
  [[ -z "$pod" ]] && return
  kubectl logs "$pod" -n "$ns" --tail="$tail" 2>/dev/null \
    | grep -i "${svc}\|error\|warn\|template\|gpu\|pending\|allowUnoptimized\|fail\|cache\|artifact\|routing" \
    | tail -30 || true
}

# --- Helper: auto-detect active serving endpoint base URL ---
# Prefers the raw deploy.sh track (an available "<model>-aim" Deployment reached
# via its Service ClusterIP), then falls back to the operator start.sh track (a
# Ready InferenceService predictor ClusterIP). Echoes a full base URL
# (http://ip[:port]); empty if nothing is serving.
detect_endpoint() {
  local ns="${NAMESPACE:-default}" ip port

  # 1. Raw deploy.sh track: an available "*-aim" Deployment and its Service.
  local dep
  dep=$(kubectl get deploy -n "$ns" -o json 2>/dev/null \
    | jq -r '.items[]
        | select((.metadata.name | endswith("-aim")) and ((.status.availableReplicas // 0) >= 1))
        | .metadata.name' 2>/dev/null | head -n1 || true)
  if [[ -n "$dep" ]]; then
    ip=$(kubectl get svc "$dep" -n "$ns" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [[ -n "$ip" && "$ip" != "None" ]]; then
      port=$(kubectl get svc "$dep" -n "$ns" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
      echo "http://${ip}:${port:-80}"
      return 0
    fi
  fi

  # 2. Operator start.sh track: a Ready InferenceService predictor ClusterIP.
  local isvc
  isvc=$(kubectl get inferenceservice -n "$ns" -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? |
        select(.type=="Ready" and .status=="True")) | .metadata.name' \
    2>/dev/null | head -n1 || true)
  if [[ -n "$isvc" ]]; then
    ip=$(kubectl get svc "${isvc}-predictor" -n "$ns" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [[ -n "$ip" && "$ip" != "None" ]]; then
      echo "http://${ip}"
      return 0
    fi
  fi
}

# =============================================================================
# Default mode: with no arguments, run the full diagnostic (--all).
# =============================================================================
if [[ $# -eq 0 ]]; then
  set -- --all
fi

# =============================================================================
# --help
# =============================================================================
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  header "AMD Enterprise AI Debug Tool"
  echo ""
  echo -e "  ${BOLD}MODES${RESET}"
  echo ""
  printf "    %-28s %s\n" "<service> [namespace]"    "Service deep-dive: conditions, pods, logs, templates, endpoint"
  printf "    %-28s %s\n" "-l, --list [namespace]"   "List all AIMServices, InferenceServices, models, templates"
  printf "    %-28s %s\n" "-g, --gpu"                "GPU node capacity, per-pod allocation, ROCm info"
  printf "    %-28s %s\n" "-c, --cluster"            "Cluster health: non-running pods, operator errors, events"
  printf "    %-28s %s\n" "-m, --cache [name] [ns]"  "AIMModelCache download deep-dive: job backoff, failed-pod logs, stall-vs-progress, HF token, Xet"
  printf "    %-28s %s\n" "-p, --portal"             "Probe AIRM + AIWB + Keycloak: URLs, credentials, pod status"
  printf "    %-28s %s\n" "-e, --endpoint [url]"     "Probe inference endpoint: smoke test, latency (auto-detects)"
  printf "    %-28s %s\n" "-a, --all [svc] [ns]"     "Run ALL modes in sequence (auto-detects service if omitted; DEFAULT when no args)"
  printf "    %-28s %s\n" "-h, --help"               "Show this help"
  echo ""
  echo -e "  ${BOLD}SERVICE-LEVEL STEPS${RESET}  (run as:  $0 <service-name> [namespace])"
  echo ""
  echo "     1.  AIMService status & state"
  echo "     2.  Conditions with blocking-cause analysis (Model / Template / RuntimeConfig)"
  echo "     3.  Spec — model, image, allowUnoptimized, template hint, RuntimeConfig"
  echo "     4.  InferenceService — URLs (external, internal, ClusterIP)"
  echo "     5.  InferenceService conditions (image pull, resources, PVC)"
  echo "     6.  Pods with resource requests (CPU / Mem / GPU)"
  echo "     7.  Pod events (image pull errors, scheduling failures, PVC binding)"
  echo "     8.  Pod logs (last 50 lines + error pattern scan)"
  echo "     9.  Live endpoint smoke test against predictor ClusterIP"
  echo "    10.  Template selection analysis (NotAvailable / ambiguous selection)"
  echo "    11.  AIMClusterModel status"
  echo "    12.  Cache & artifact status + download job logs (StorageSizeError, RWX)"
  echo "    13.  Routing — HTTPRoute + Gateway health"
  echo "    14.  RuntimeConfig reference validation"
  echo "    15.  Operator logs filtered by resource name (JSON structured logs)"
  echo "    16.  Diagnostic summary with state-driven fix guidance"
  echo ""
  echo -e "  ${BOLD}EXAMPLES${RESET}"
  echo ""
  echo "    $0 gpt-oss-120b"
  echo "    $0 gpt-oss-120b default"
  echo "    $0 -l"
  echo "    $0 -l default"
  echo "    $0 -g"
  echo "    $0 -c"
  echo "    $0 -m"
  echo "    $0 -m openai-gpt-oss-120b"
  echo "    $0 -p"
  echo "    $0 -e"
  echo "    $0 -e http://10.243.213.135"
    echo "    $0                         # no args = --all (full diagnostic)"
    echo "    $0 -a"
    echo "    $0 -a gpt-oss-120b"
    echo "    $0 -a gpt-oss-120b default"
  echo ""
  echo -e "  ${DIM}Docs: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html${RESET}"
  echo ""
  exit 0
fi


# =============================================================================
# -a | --all  — run every debug mode in sequence
# =============================================================================
if [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]]; then
  SCRIPT="$(realpath "$0")"
  ALL_SVC="${2:-}"
  ALL_NS="${3:-default}"

  # Auto-detect a running service if none supplied
  if [[ -z "$ALL_SVC" ]]; then
    ALL_SVC=$(kubectl get aimservices -A --no-headers 2>/dev/null \
      | awk '{print $2}' | head -1 || true)
  fi

  SEP="$(printf '=%.0s' $(seq 1 60))"

  run_section() {
    local flag="$1"; shift
    echo ""
    echo -e "${BOLD}${CYAN}${SEP}${RESET}"
    echo -e "${BOLD}  Running: $0 ${flag} $*${RESET}"
    echo -e "${BOLD}${CYAN}${SEP}${RESET}"
    bash "$SCRIPT" "$flag" "$@" || true
  }

  header "AMD Enterprise AI — Full Diagnostic"
  [[ -n "$ALL_SVC" ]] && info "Service target: ${ALL_SVC} (ns: ${ALL_NS})"
  echo ""

  run_section -l
  run_section -g
  run_section -c
  run_section -m
  run_section -p
  run_section -e
  if [[ -n "$ALL_SVC" ]]; then
    run_section "$ALL_SVC" "$ALL_NS"
  else
    warn "No service name provided and none auto-detected — skipping service deep-dive."
    info "Run:  $0 -a <service-name> [namespace]"
  fi

  echo ""
  header "Full Diagnostic Complete"
  info "Docs: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html"
  echo ""
  exit 0
fi

# =============================================================================
# --list
# =============================================================================
if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
  NS="${2:-}"
  header "AIM Engine — Resource Catalog"

  section "AIMServices"
  if [[ -n "$NS" ]]; then
    kubectl get aimservices -n "$NS" \
      -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,STATE:.status.state,READY:.status.conditions[?(@.type=='Ready')].status,TEMPLATE:.status.templateName,AGE:.metadata.creationTimestamp" \
      2>/dev/null || warn "No AIMServices found in namespace: $NS"
  else
    kubectl get aimservices -A \
      -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,STATE:.status.state,READY:.status.conditions[?(@.type=='Ready')].status,TEMPLATE:.status.templateName,AGE:.metadata.creationTimestamp" \
      2>/dev/null || warn "No AIMServices found."
  fi

  section "InferenceServices"
  kubectl get inferenceservice -A \
    -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,READY:.status.conditions[?(@.type=='Ready')].status,URL:.status.url,AGE:.metadata.creationTimestamp" \
    2>/dev/null || warn "No InferenceServices found."

  section "AIMClusterModels"
  kubectl get aimclustermodels \
    -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,IMAGE:.spec.image,AGE:.metadata.creationTimestamp" \
    2>/dev/null || warn "No AIMClusterModels found."

  section "AIMServiceTemplates (All Namespaces)"
  # Docs: status NotAvailable = required GPU not in cluster
  #       status not Ready    = still discovering or failed
  kubectl get aimservicetemplates -A \
    -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,STATUS:.status.status,MODEL:.spec.model.name" \
    2>/dev/null || warn "No AIMServiceTemplates found."

  section "AIMClusterServiceTemplates"
  kubectl get aimclusterservicetemplates \
    -o custom-columns="NAME:.metadata.name,STATUS:.status.status,MODEL:.spec.model.name" \
    2>/dev/null || warn "No AIMClusterServiceTemplates found."

  section "Cache & Artifacts (default ns)"
  NS_CACHE="${NS:-default}"
  kubectl get aimtemplatecache -n "$NS_CACHE" 2>/dev/null \
    -o custom-columns="NAME:.metadata.name,STATUS:.status.status,PVC:.spec.pvcName" \
    || warn "No AIMTemplateCache found in ${NS_CACHE}."
  kubectl get aimartifact -n "$NS_CACHE" 2>/dev/null | head -10 \
    || warn "No AIMArtifact found in ${NS_CACHE}."

  section "Active Predictor ClusterIP Services"
  kubectl get svc -A --no-headers 2>/dev/null \
    | grep -i "predictor" \
    | awk '{printf "  %-42s %-15s %s\n", $2, $1, $4}' \
    || warn "No predictor services found."

  echo ""
  info "Docs: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html"
  echo ""
  exit 0
fi

# =============================================================================
# --gpu
# =============================================================================
if [[ "${1:-}" == "--gpu" || "${1:-}" == "-g" ]]; then
  header "GPU & Node Status"

  section "Kubernetes Nodes"
  kubectl get nodes -o wide 2>/dev/null

  section "GPU Capacity & Allocatable Per Node"
  if $HAS_JQ; then
    kubectl get nodes -o json 2>/dev/null | jq -r '
      .items[] |
      "  Node: \(.metadata.name)\n" +
      "    Capacity    amd.com/gpu = \(.status.capacity["amd.com/gpu"] // "0")\n" +
      "    Allocatable amd.com/gpu = \(.status.allocatable["amd.com/gpu"] // "0")\n" +
      "    Memory (alloc)          = \(.status.allocatable.memory)\n" +
      "    CPU    (alloc)          = \(.status.allocatable.cpu)"
    ' 2>/dev/null
  else
    kubectl describe nodes 2>/dev/null | grep -A5 "Allocatable:" | grep -i "gpu\|mem\|cpu" || true
  fi

  section "GPU Allocation by Running Pod"
  kubectl get pods -A --field-selector=status.phase=Running -o json 2>/dev/null \
    | jq -r '
      .items[] |
      select(.spec.containers[].resources.limits["amd.com/gpu"] // "" | . != "") |
      "  \(.metadata.namespace)/\(.metadata.name)  →  \(.spec.containers[].resources.limits["amd.com/gpu"] // "0") GPU(s)"
    ' 2>/dev/null | sort | uniq \
    || info "No pods with explicit GPU limits found."

  section "Detected GPU Models (from AIMClusterModels)"
  kubectl get aimclustermodels -o json 2>/dev/null \
    | jq -r '.items[].status.imageMetadata.model.recommendedDeployments[]?.gpuModel' \
    2>/dev/null | sort -u | sed 's/^/  • /' \
    || warn "GPU model data not available in AIMClusterModels."

  section "Node Conditions"
  if $HAS_JQ; then
    kubectl get nodes -o json 2>/dev/null \
      | jq -r '.items[] | .metadata.name as $n | .status.conditions[] |
          "  \($n)  \(.type): \(.status)  (\(.reason // "-"))"' \
      2>/dev/null | column -t || true
  else
    kubectl get nodes 2>/dev/null
  fi

  section "ROCm GPU Info (rocm-smi)"
  if command -v rocm-smi &>/dev/null; then
    rocm-smi 2>/dev/null || warn "rocm-smi returned an error."
  else
    warn "rocm-smi not available on this host (expected on a GPU node)."
  fi

  section "AIM Engine Accelerator Detection Logs"
  AIM_NS_POD=$(find_aim_operator)
  AIM_NS="${AIM_NS_POD%%/*}"; AIM_POD="${AIM_NS_POD##*/}"
  if [[ -n "$AIM_POD" ]]; then
    ok "Controller pod: ${AIM_POD} (ns: ${AIM_NS})"
    kubectl logs "$AIM_POD" -n "$AIM_NS" --tail=200 2>/dev/null \
      | grep -i "accelerator\|gpu\|detected\|mi3\|nodePool\|rocm\|nodeClass" \
      || warn "No GPU detection entries found in recent controller logs."
  else
    warn "AIM Engine/Kaiwo controller pod not found — check: kubectl get pods -A"
  fi
  echo ""
  exit 0
fi

# =============================================================================
# --cluster
# =============================================================================
if [[ "${1:-}" == "--cluster" || "${1:-}" == "-c" ]]; then
  header "Cluster & Operator Health"

  section "Node Status"
  kubectl get nodes -o wide 2>/dev/null

  section "Non-Running / Non-Completed Pods (All Namespaces)"
  NOT_RUNNING=$(kubectl get pods -A --no-headers 2>/dev/null \
    | grep -Ev "\bRunning\b|\bCompleted\b" || true)
  if [[ -n "$NOT_RUNNING" ]]; then
    echo "$NOT_RUNNING" | column -t
  else
    ok "All pods are Running or Completed."
  fi

  section "AIM Engine Operator (aim-system / kaiwo-system)"
  AIM_NS_POD=$(find_aim_operator)
  AIM_NS="${AIM_NS_POD%%/*}"; AIM_POD="${AIM_NS_POD##*/}"
  if [[ -n "$AIM_POD" ]]; then
    ok "Controller pod: ${AIM_POD} (ns: ${AIM_NS})"
    kubectl get pod "$AIM_POD" -n "$AIM_NS" -o wide 2>/dev/null
    echo ""
    info "Recent ERROR/WARN/FAIL in operator logs:"
    kubectl logs "$AIM_POD" -n "$AIM_NS" --tail=300 2>/dev/null \
      | grep -i "error\|warn\|fail\|panic" | tail -20 \
      || info "No error-level entries in recent operator logs."
  else
    warn "AIM Engine controller pod not found."
    info "Expected: deployment/aim-engine-controller-manager in aim-system"
    info "      or: kaiwo-controller-manager in kaiwo-system"
  fi

  section "KServe Control Plane"
  kubectl get pods -n kserve -o wide 2>/dev/null \
    || kubectl get pods -n knative-serving -o wide 2>/dev/null \
    || info "KServe namespace (kserve / knative-serving) not found."

  section "AIMService Summary (All Namespaces)"
  # Shows all 8 status values from the docs
  kubectl get aimservices -A \
    -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,STATE:.status.state,READY:.status.conditions[?(@.type=='Ready')].status" \
    2>/dev/null

  section "Storage / PVC Status"
  kubectl get pvc -A 2>/dev/null | grep -Ev "^$" \
    || info "No PVCs found."

  section "Longhorn Volumes (storage backend)"
  kubectl get volumes.longhorn.io -n longhorn-system 2>/dev/null | head -20 \
    || info "Longhorn not accessible (may use a different storage class)."

  section "Recent Warning Events (All Namespaces)"
  kubectl get events -A --field-selector=type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -25 \
    || info "No Warning events found."

  section "Gateway Resources (for Routing)"
  kubectl get gateway -A 2>/dev/null \
    || info "No Gateway resources found."

  echo ""
  info "Docs: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html"
  echo ""
  exit 0
fi

# =============================================================================
# --portal
# Probes AMD Resource Manager (AIRM) and AMD AI Workbench (AIWB) portals.
# Auto-detects node IP and builds nip.io URLs.
# Credentials: devuser password from airm-realm-credentials secret (keycloak ns)
# =============================================================================
if [[ "${1:-}" == "--portal" || "${1:-}" == "-p" ]]; then
  header "Portal Health — AIRM & AIWB"

  if ! $HAS_CURL; then
    error "curl is required for portal health checks."
    exit 1
  fi

  # ── Domain & IP Detection ────────────────────────────────────────────────────
  section "Domain & IP Detection"
  
  # 1. Detect Master Node IP
  NODE_IP=$(kubectl get nodes -o json 2>/dev/null \
    | jq -r '.items[0].status.addresses[] | select(.type=="ExternalIP") | .address' \
    2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [[ -z "$NODE_IP" ]]; then
    NODE_IP=$(kubectl get nodes -o json 2>/dev/null \
      | jq -r '.items[0].status.addresses[] | select(.type=="InternalIP") | .address' \
      2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi
  if [[ -n "$NODE_IP" ]]; then
    ok "Master node IP: ${NODE_IP}"
  else
    warn "Could not detect node IP."
  fi

  # 2. Detect Domain
  DOMAIN=""
  # Try to read domain from Gateway hostname
  GW_HOSTNAME=$(kubectl get gateway -n kgateway-system https -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}' 2>/dev/null || true)
  if [[ -n "$GW_HOSTNAME" ]]; then
    # strip leading '*.' if present
    DOMAIN="${GW_HOSTNAME#\*.}"
  fi

  # Fallback to bloom.yaml
  if [[ -z "$DOMAIN" ]]; then
    SCRIPT_DIR="$(dirname "$(realpath "$0")")"
    if [[ -f "${SCRIPT_DIR}/bloom.yaml" ]]; then
      DOMAIN=$(grep -E '^DOMAIN:' "${SCRIPT_DIR}/bloom.yaml" | awk '{print $2}' || true)
    elif [[ -f "${SCRIPT_DIR}/scripts/bloom.yaml" ]]; then
      DOMAIN=$(grep -E '^DOMAIN:' "${SCRIPT_DIR}/scripts/bloom.yaml" | awk '{print $2}' || true)
    fi
  fi

  # Fallback to Node IP + nip.io
  if [[ -z "$DOMAIN" && -n "$NODE_IP" ]]; then
    DOMAIN="${NODE_IP}.nip.io"
  fi

  if [[ -z "$DOMAIN" ]]; then
    error "Could not detect domain. Ensure kubectl is configured correctly."
    exit 1
  fi
  ok "Configured Domain: ${DOMAIN}"

  AIRM_URL="https://airmui.${DOMAIN}"
  AIWB_URL="https://aiwbui.${DOMAIN}"
  KC_URL="https://kc.${DOMAIN}"

  # ── SSL/TLS Certificate Verification ─────────────────────────────────────────
  section "SSL/TLS Certificate Verification"
  
  # 1. Verify cluster-tls Kubernetes Secret
  if kubectl get secret cluster-tls -n kgateway-system &>/dev/null; then
    ok "Found 'cluster-tls' secret in 'kgateway-system' namespace."
    cert_data=$(kubectl get secret cluster-tls -n kgateway-system -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -n "$cert_data" ]]; then
      expiry=$(echo "$cert_data" | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2- || echo "Unknown")
      subject=$(echo "$cert_data" | openssl x509 -subject -noout 2>/dev/null | sed 's/subject= //' || echo "Unknown")
      issuer=$(echo "$cert_data" | openssl x509 -issuer -noout 2>/dev/null | sed 's/issuer= //' || echo "Unknown")
      bullet "Secret Cert Subject : $subject"
      bullet "Secret Cert Issuer  : $issuer"
      bullet "Secret Cert Expiry  : $expiry"

      expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
      now_epoch=$(date +%s)
      if [[ "$expiry_epoch" -gt 0 ]]; then
        if [[ "$now_epoch" -gt "$expiry_epoch" ]]; then
          error "The SSL certificate in secret 'cluster-tls' has EXPIRED!"
        else
          days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
          ok "Secret certificate is valid ($days_left days remaining)."
        fi
      fi
    else
      warn "Secret 'cluster-tls' exists but does not contain 'tls.crt' data."
    fi
  else
    warn "Secret 'cluster-tls' not found in namespace 'kgateway-system'."
  fi

  # 2. Verify network SSL/TLS handshake
  ssl_host="airmui.${DOMAIN}"
  info "Probing SSL certificate for ${ssl_host} over network..."
  ssl_output=$(echo | openssl s_client -connect "${ssl_host}:443" -servername "${ssl_host}" 2>/dev/null || true)
  if [[ -n "$ssl_output" && $(echo "$ssl_output" | grep -i "BEGIN CERTIFICATE") ]]; then
    net_expiry=$(echo "$ssl_output" | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2- || echo "Unknown")
    net_subject=$(echo "$ssl_output" | openssl x509 -subject -noout 2>/dev/null | sed 's/subject= //' || echo "Unknown")
    net_issuer=$(echo "$ssl_output" | openssl x509 -issuer -noout 2>/dev/null | sed 's/issuer= //' || echo "Unknown")
    bullet "Network Cert Subject: $net_subject"
    bullet "Network Cert Issuer : $net_issuer"
    bullet "Network Cert Expiry : $net_expiry"

    now_epoch=$(date +%s)
    net_expiry_epoch=$(date -d "$net_expiry" +%s 2>/dev/null || echo "0")
    if [[ "$net_expiry_epoch" -gt 0 ]]; then
      if [[ "$now_epoch" -gt "$net_expiry_epoch" ]]; then
        error "The network SSL certificate for ${ssl_host} has EXPIRED!"
      else
        net_days_left=$(( (net_expiry_epoch - now_epoch) / 86400 ))
        ok "Network SSL certificate is valid ($net_days_left days remaining)."
      fi
    fi
  else
    warn "Could not establish SSL connection to ${ssl_host}:443 over network."
    fix "Check if DNS / local host routing is configured, and if the Gateway is running on port 443."
  fi

  # ── Portal URL probe ─────────────────────────────────────────────────────────
  section "Portal Reachability"
  probe_portal() {
    local label="$1" url="$2"
    local code
    code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    # 200 = direct hit, 30x = redirect to auth (healthy), 404 = not deployed, 000 = timeout
    case "$code" in
      200|30[0-9])
        ok "${label}  →  HTTP ${code}  (reachable)"
        echo "        URL: ${url}"
        ;;
      000)
        fail "${label}  →  no response / timeout"
        echo "        URL: ${url}"
        ;;
      *)
        warn "${label}  →  HTTP ${code}"
        echo "        URL: ${url}"
        ;;
    esac
  }

  probe_portal "AMD Resource Manager (AIRM)" "$AIRM_URL"
  probe_portal "AMD AI Workbench   (AIWB)" "$AIWB_URL"
  probe_portal "Keycloak (IdP)            " "$KC_URL"

  # ── Credentials ─────────────────────────────────────────────────────────────
  section "Login Credentials"

  echo -e "  ${BOLD}AMD Resource Manager (AIRM)${RESET}"
  echo "    Login URL : ${AIRM_URL}"
  echo "    Username  : devuser@${DOMAIN}"
  echo "    Password  : managed via Keycloak — use your Keycloak credentials"


  echo ""
  echo -e "  ${BOLD}AMD AI Workbench (AIWB)${RESET}"
  echo "    Login URL : ${AIWB_URL}"
  echo "    Users     : managed via Keycloak — use your Keycloak credentials"
  echo "    Keycloak  : ${KC_URL}"

  # Keycloak admin password
  KC_ADMIN_PASS=$(kubectl get secret keycloak-credentials -n keycloak \
    -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "$KC_ADMIN_PASS" ]]; then
    echo ""
    echo -e "  ${BOLD}Keycloak Admin${RESET}"
    echo "    Login URL : ${KC_URL}/admin"
    echo "    Username  : admin"
    echo "    Password  : ${KC_ADMIN_PASS}"
    echo "    (from secret keycloak-credentials in keycloak namespace)"
  fi

  # ── Underlying service health ────────────────────────────────────────────────
  section "Underlying Kubernetes Services"
  echo "  AIRM namespace:"
  kubectl get pods -n airm --no-headers 2>/dev/null \
    | awk '{printf "    %-45s %s\n", $1, $3}' || warn "Cannot list airm pods."
  echo ""
  echo "  Keycloak namespace:"
  kubectl get pods -n keycloak --no-headers 2>/dev/null \
    | awk '{printf "    %-45s %s\n", $1, $3}' || warn "Cannot list keycloak pods."

  # ── Quick summary ────────────────────────────────────────────────────────────
  section "Summary"
  echo "  Access matrix:"
  echo ""
  printf "  %-30s %s\n" "Portal" "URL"
  printf "  %-30s %s\n" "──────────────────────────────" "────────────────────────────────────────"
  printf "  %-30s %s\n" "AMD Resource Manager (AIRM)" "${AIRM_URL}"
  printf "  %-30s %s\n" "AMD AI Workbench (AIWB)" "${AIWB_URL}"
  printf "  %-30s %s\n" "Keycloak (IdP)" "${KC_URL}"
  echo ""
  info "Once signed in to either portal, you can navigate to the other without signing in again."
  info "Docs: https://enterprise-ai.docs.amd.com/en/latest/"
  echo ""
  exit 0
fi

# =============================================================================
# --endpoint
# =============================================================================
if [[ "${1:-}" == "--endpoint" || "${1:-}" == "-e" ]]; then
  TARGET="${2:-}"
  header "Inference Endpoint Probe"

  if [[ -z "$TARGET" ]]; then
    info "No URL provided — auto-detecting from cluster (deploy.sh raw track preferred)..."
    TARGET=$(detect_endpoint)
    if [[ -n "$TARGET" ]]; then
      info "Detected endpoint: ${TARGET}"
    else
      error "Could not auto-detect an active serving endpoint."
      info "Usage: $0 --endpoint http://<ip-or-hostname>"
      exit 1
    fi
  fi

  if ! $HAS_CURL; then
    error "curl is required for endpoint probing but was not found."
    exit 1
  fi

  # ── /v1/models ──────────────────────────────────────────────────────────────
  section "Model Listing (/v1/models)"
  MODELS_RESP=$(curl -sf --max-time 10 "${TARGET}/v1/models" 2>/dev/null || true)
  if [[ -n "$MODELS_RESP" ]]; then
    ok "GET ${TARGET}/v1/models → 200"
    if $HAS_JQ; then
      echo "$MODELS_RESP" | jq -r '.data[] | "  • \(.id)  (created: \(.created // "-"))"' \
        2>/dev/null || echo "$MODELS_RESP" | indent
    else
      echo "$MODELS_RESP" | indent
    fi
    MODEL_ID=$(echo "$MODELS_RESP" | jq -r '.data[0].id' 2>/dev/null || echo "unknown")
  else
    fail "GET ${TARGET}/v1/models — no response"
    info "Is the service Running? Try: $0 --list"
    exit 1
  fi

  # ── Health / readiness ───────────────────────────────────────────────────────
  section "Health Endpoints"
  for path in /health /v1/health /readyz /healthz; do
    HTTP_STATUS=$(curl -o /dev/null -sf --max-time 5 -w "%{http_code}" \
      "${TARGET}${path}" 2>/dev/null || echo "000")
    if [[ "$HTTP_STATUS" == "200" ]]; then
      ok "  ${path} → HTTP ${HTTP_STATUS}"
    else
      dim "  ${path} → HTTP ${HTTP_STATUS}"
    fi
  done

  # ── Smoke test ───────────────────────────────────────────────────────────────
  section "Smoke Test (Completions API)"
  info "Model: ${MODEL_ID}"
  SMOKE_PAYLOAD=$(printf '{"model":"%s","prompt":"The capital of France is","max_tokens":10,"temperature":0}' "$MODEL_ID")
  T0=$(date +%s%N)
  SMOKE_RESP=$(curl -sf --max-time 30 \
    -H "Content-Type: application/json" \
    -d "$SMOKE_PAYLOAD" \
    "${TARGET}/v1/completions" 2>/dev/null || true)
  T1=$(date +%s%N)
  SMOKE_MS=$(( (T1 - T0) / 1000000 ))

  if [[ -n "$SMOKE_RESP" ]]; then
    ok "Completions API responded in ${SMOKE_MS}ms"
    if $HAS_JQ; then
      COMPLETION=$(echo "$SMOKE_RESP" | jq -r '.choices[0].text' 2>/dev/null || echo "(parse error)")
      USAGE=$(echo "$SMOKE_RESP" | jq -r \
        '"prompt=\(.usage.prompt_tokens) completion=\(.usage.completion_tokens) total=\(.usage.total_tokens)"' \
        2>/dev/null || echo "")
      bullet "Completion : ${COMPLETION}"
      bullet "Token usage: ${USAGE}"
    else
      echo "$SMOKE_RESP" | indent
    fi
  else
    fail "Smoke test FAILED — no response within 30s."
    warn "Service may be warming up or overloaded."
  fi

  # ── Latency micro-benchmark ──────────────────────────────────────────────────
  section "Latency Micro-benchmark (5 × short requests)"
  TOTAL_MS=0; MIN_MS=9999999; MAX_MS=0
  for i in $(seq 1 5); do
    T0=$(date +%s%N)
    curl -sf --max-time 30 \
      -H "Content-Type: application/json" \
      -d "$SMOKE_PAYLOAD" \
      "${TARGET}/v1/completions" &>/dev/null || true
    T1=$(date +%s%N)
    T_MS=$(( (T1 - T0) / 1000000 ))
    TOTAL_MS=$(( TOTAL_MS + T_MS ))
    [[ $T_MS -lt $MIN_MS ]] && MIN_MS=$T_MS
    [[ $T_MS -gt $MAX_MS ]] && MAX_MS=$T_MS
    dim "  Request ${i}: ${T_MS}ms"
  done
  AVG_MS=$(( TOTAL_MS / 5 ))
  ok "Avg: ${AVG_MS}ms   Min: ${MIN_MS}ms   Max: ${MAX_MS}ms"

  echo ""
  exit 0
fi

# =============================================================================
# --cache  — AIMModelCache download deep-dive
#
# Root-causes model cache download failures that otherwise surface only as a
# generic "stalled" / "Failed" status. For each cache it reports:
#   - AIMModelCache status + conditions (StorageReady / Progressing / Failure)
#   - The owning download Job: backoffLimit, failed/active counts, BackoffLimitExceeded
#   - Every download pod (current + failed/terminated) with phase, restarts,
#     terminated reason + exit code, and waiting reason (e.g. ImagePullBackOff)
#   - Logs from the current pod AND failed/previous pods, scanned for known
#     failure signatures (image pull, "too large", hf_xet, 401/403/429, ENOSPC, OOM)
#   - Progress sampling (du/df sampled twice) to distinguish a real stall from
#     a slow-but-moving download
#   - PVC + Longhorn volume health, HF token presence, downloader image presence
# =============================================================================
if [[ "${1:-}" == "--cache" || "${1:-}" == "-m" ]]; then
  CACHE_NAME="${2:-}"
  CACHE_NS="${3:-default}"

  header "AIMModelCache — Download Diagnostics  (ns: ${CACHE_NS})"

  # Resolve target cache list (specific name, or all caches in the namespace)
  if [[ -n "$CACHE_NAME" ]]; then
    CACHE_TARGETS="$CACHE_NAME"
  else
    CACHE_TARGETS=$(kubectl get aimmodelcache -n "$CACHE_NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  fi

  if [[ -z "$CACHE_TARGETS" ]]; then
    warn "No AIMModelCache resources found in namespace '${CACHE_NS}'."
    info "List caches: kubectl get aimmodelcache -A"
    exit 0
  fi

  # --- Scan a pod's logs for known failure signatures and map to a fix ---
  scan_log_signatures() {
    local logtext="$1"
    [[ -z "$logtext" ]] && return
    local lc; lc=$(echo "$logtext" | tr '[:upper:]' '[:lower:]')
    if echo "$lc" | grep -q "too large to be downloaded using the regular download"; then
      fail   "Signature: large file blocked on plain HTTP (hf_xet/hf_transfer not active)"
      fix    "The downloader venv (/prod_venv) must have a compatible huggingface_hub + hf_xet."
      fix    "Rebuild: ./scripts/build-gpt-oss-downloader.sh  (installs requirements-downloader.txt into /prod_venv)"
    fi
    if echo "$lc" | grep -q "hf_xet.*not installed\|xet storage is enabled.*not installed"; then
      warn   "Signature: hf_xet present but not engaged by huggingface_hub → falling back to HTTP"
      fix    "Ensure huggingface_hub>=0.34 is installed into /prod_venv (not /usr/local)."
    fi
    if echo "$lc" | grep -qE "imagepullbackoff|errimagepull|manifest unknown|not found: manifest"; then
      fail   "Signature: download image could not be pulled"
      fix    "Build + import the image: ./scripts/build-gpt-oss-downloader.sh"
      fix    "Verify in containerd: sudo ${RKE2_CTR:-/var/lib/rancher/rke2/bin/ctr} -a ${RKE2_SOCK:-/run/k3s/containerd/containerd.sock} -n k8s.io images ls | grep downloader"
    fi
    if echo "$lc" | grep -qE "401|403|unauthorized|gated|access to model|restricted"; then
      fail   "Signature: Hugging Face auth/authorization error (gated or private repo)"
      fix    "Set a valid HF_TOKEN with access to the repo (see HF token check below)."
    fi
    if echo "$lc" | grep -qE "429|rate limit|too many requests"; then
      warn   "Signature: Hugging Face rate limiting (unauthenticated or heavy traffic)"
      fix    "Set HF_TOKEN for higher rate limits; retry."
    fi
    if echo "$lc" | grep -qE "no space left|enospc|disk quota|storagesizeerror"; then
      fail   "Signature: ran out of cache storage"
      fix    "Increase the AIMModelCache 'size' and recreate the cache."
    fi
    if echo "$lc" | grep -qE "oomkilled|out of memory|killed"; then
      warn   "Signature: possible OOM kill of the download container"
      fix    "Increase the download job memory or reduce concurrency."
    fi
    if echo "$lc" | grep -qE "connection reset|timed out|timeout|temporary failure in name resolution|tls handshake"; then
      warn   "Signature: network instability talking to the model source"
      fix    "Check egress/DNS to huggingface.co and the Xet CDN; retry."
    fi
  }

  for C in $CACHE_TARGETS; do
    echo ""
    echo -e "${BOLD}${CYAN}$(printf '=%.0s' $(seq 1 64))${RESET}"
    echo -e "${BOLD}  Cache: ${C}${RESET}"
    echo -e "${BOLD}${CYAN}$(printf '=%.0s' $(seq 1 64))${RESET}"

    if ! kubectl get aimmodelcache "$C" -n "$CACHE_NS" >/dev/null 2>&1; then
      error "AIMModelCache '${C}' not found in namespace '${CACHE_NS}'."
      continue
    fi

    # --- 1. Cache status + spec ---
    section "1. AIMModelCache — Status & Spec"
    kubectl get aimmodelcache "$C" -n "$CACHE_NS" 2>/dev/null
    if $HAS_JQ; then
      kubectl get aimmodelcache "$C" -n "$CACHE_NS" -o json 2>/dev/null | jq -r '
        "  Status        : \(.status.status // "-")\n" +
        "  Source URI    : \(.spec.sourceUri // "-")\n" +
        "  Requested size: \(.spec.size // "-")\n" +
        "  Download image: \(.spec.modelDownloadImage // "(operator default)")\n" +
        "  PVC           : \(.status.persistentVolumeClaim // "-")"' 2>/dev/null || true
      echo ""
      info "Conditions:"
      kubectl get aimmodelcache "$C" -n "$CACHE_NS" -o json 2>/dev/null \
        | jq -r '.status.conditions[]? | "  \(.type)=\(.status)  reason=\(.reason // "-")  \(.message // "")"' \
        2>/dev/null || true
    fi

    PVC=$(kubectl get aimmodelcache "$C" -n "$CACHE_NS" \
      -o jsonpath='{.status.persistentVolumeClaim}' 2>/dev/null || true)
    SRC_URI=$(kubectl get aimmodelcache "$C" -n "$CACHE_NS" \
      -o jsonpath='{.spec.sourceUri}' 2>/dev/null || true)
    DL_IMAGE=$(kubectl get aimmodelcache "$C" -n "$CACHE_NS" \
      -o jsonpath='{.spec.modelDownloadImage}' 2>/dev/null || true)

    # --- 2. Download Job: backoff / failures ---
    section "2. Download Job — Retry Budget & Status"
    JOB="${C}-cache-download"
    if kubectl get job "$JOB" -n "$CACHE_NS" >/dev/null 2>&1; then
      if $HAS_JQ; then
        kubectl get job "$JOB" -n "$CACHE_NS" -o json 2>/dev/null | jq -r '
          "  backoffLimit  : \(.spec.backoffLimit // "-")  (job fails permanently after this many pod failures)\n" +
          "  active        : \(.status.active // 0)\n" +
          "  succeeded     : \(.status.succeeded // 0)\n" +
          "  failed        : \(.status.failed // 0)\n" +
          "  startTime     : \(.status.startTime // "-")"' 2>/dev/null || true
        JOB_FAILED_COND=$(kubectl get job "$JOB" -n "$CACHE_NS" -o json 2>/dev/null \
          | jq -r '.status.conditions[]? | select(.type=="Failed") | "\(.reason): \(.message)"' 2>/dev/null || true)
        if [[ -n "$JOB_FAILED_COND" ]]; then
          echo ""
          fail "Job has FAILED → ${JOB_FAILED_COND}"
          [[ "$JOB_FAILED_COND" == *BackoffLimitExceeded* ]] && \
            fix "Retry budget exhausted. Fix the root cause below, then delete + recreate the cache."
        fi
      else
        kubectl get job "$JOB" -n "$CACHE_NS" 2>/dev/null
      fi
    else
      warn "No download Job '${JOB}' found (cache may already be Available, or not started)."
    fi

    # --- 3. Download pods: current + failed history ---
    section "3. Download Pods — Current & Failed History"
    DL_PODS=$(kubectl get pods -n "$CACHE_NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep "^${C}-cache-download" || true)
    if [[ -z "$DL_PODS" ]]; then
      warn "No download pods found for cache '${C}'."
    fi

    RUNNING_POD=""
    for P in $DL_PODS; do
      PHASE=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
      RESTARTS=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
      WAIT_REASON=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
      TERM_REASON=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
      TERM_EXIT=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
      LAST_TERM=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
      DETAIL="phase=${PHASE} restarts=${RESTARTS}"
      [[ -n "$WAIT_REASON" ]] && DETAIL="${DETAIL} waiting=${WAIT_REASON}"
      [[ -n "$TERM_REASON" ]] && DETAIL="${DETAIL} terminated=${TERM_REASON}(exit=${TERM_EXIT})"
      [[ -n "$LAST_TERM" ]]   && DETAIL="${DETAIL} lastTerminated=${LAST_TERM}"
      case "$PHASE" in
        Running)   ok   "${P}  ${DETAIL}"; RUNNING_POD="$P" ;;
        Succeeded) ok   "${P}  ${DETAIL}" ;;
        Failed)    fail "${P}  ${DETAIL}" ;;
        *)         warn "${P}  ${DETAIL}" ;;
      esac
    done

    # --- 4. Logs + signature scan (failed pods first, then current) ---
    section "4. Logs & Failure-Signature Scan"
    for P in $DL_PODS; do
      PHASE=$(kubectl get pod "$P" -n "$CACHE_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
      [[ "$PHASE" == "Running" || "$PHASE" == "Failed" || "$PHASE" == "Error" ]] || continue
      echo ""
      info "── ${P} (${PHASE}) — last 15 log lines ──"
      LOGS=$(kubectl logs "$P" -n "$CACHE_NS" --tail=15 2>/dev/null || true)
      # Include previous container logs if the pod restarted
      PREV_LOGS=$(kubectl logs "$P" -n "$CACHE_NS" --previous --tail=15 2>/dev/null || true)
      if [[ -n "$LOGS" ]]; then echo "$LOGS" | indent; else dim "  (no current logs)"; fi
      if [[ -n "$PREV_LOGS" ]]; then echo ""; dim "  (previous container instance):"; echo "$PREV_LOGS" | indent; fi
      scan_log_signatures "${LOGS}
${PREV_LOGS}"
    done

    # --- 5. Progress sampling (stall vs slow) ---
    if [[ -n "$RUNNING_POD" ]]; then
      section "5. Progress Sampling (throughput, stall vs slow)"
      # Count both total cache bytes AND the sum of in-flight .incomplete files.
      # Xet/HF download in bursts with inter-chunk pauses, so we take a longer
      # window and a confirmation sample before declaring a true stall.
      read_bytes() {
        kubectl exec "$RUNNING_POD" -n "$CACHE_NS" 2>/dev/null -- sh -c '
          tot=$(du -sb /cache 2>/dev/null | cut -f1)
          inc=$(du -cb /cache/.cache/huggingface/download/*.incomplete 2>/dev/null | tail -1 | cut -f1)
          echo "${tot:-0} ${inc:-0}"' 2>/dev/null || echo "0 0"
      }
      sample_window() {
        local secs="$1" b0 b1 t0 i0 t1 i1
        b0=$(read_bytes); t0=${b0% *}; i0=${b0#* }
        sleep "$secs"
        b1=$(read_bytes); t1=${b1% *}; i1=${b1#* }
        # movement = larger of total-dir growth or incomplete-file growth
        local dt=$(( ${t1:-0} - ${t0:-0} )) di=$(( ${i1:-0} - ${i0:-0} ))
        local mv=$dt; [[ $di -gt $mv ]] && mv=$di
        echo "$mv $t0 $t1"
      }
      info "Sampling download throughput over ~20s (with confirmation on no-growth)..."
      read MV T0 T1 < <(sample_window 20)
      RATE=$(( MV / 20 / 1024 ))  # KB/s
      bullet "Cache total: $(( ${T0:-0}/1024/1024 )) MB → $(( ${T1:-0}/1024/1024 )) MB"
      bullet "Movement: $(( MV/1024/1024 )) MB in 20s  (~${RATE} KB/s)"
      if [[ "$MV" -gt 0 ]]; then
        if [[ "$RATE" -lt 5120 ]]; then
          warn "Download is MOVING but SLOW (~${RATE} KB/s ≈ $(( RATE/1024 )) MB/s)."
          bullet "A multi-hundred-GB model at this rate can take many hours and may trip watchdogs."
          fix "Set HF_TOKEN (higher rate limits) and confirm hf_xet/hf_transfer is active in /prod_venv."
        else
          ok "Download is MOVING at ~$(( RATE/1024 )) MB/s. Healthy — let it run."
        fi
      else
        # Confirm with a second, longer window before calling it stalled
        warn "No growth in first window — confirming over another 20s..."
        read MV2 _ _ < <(sample_window 20)
        if [[ "$MV2" -gt 0 ]]; then
          ok "Movement resumed (+$(( MV2/1024/1024 )) MB) — burst-y download, not stalled."
        else
          fail "No byte growth across two 20s windows — download appears STALLED."
          fix "Inspect the running pod logs above for network/auth/rate-limit signatures."
          fix "Check egress to huggingface.co + Xet CDN; verify HF_TOKEN; consider recreating the cache."
        fi
      fi
      echo ""
      info "Filesystem usage on cache volume:"
      kubectl exec "$RUNNING_POD" -n "$CACHE_NS" 2>/dev/null -- sh -c 'df -h /cache 2>/dev/null | tail -1' | indent || true
      info "In-flight (.incomplete) files:"
      kubectl exec "$RUNNING_POD" -n "$CACHE_NS" 2>/dev/null -- sh -c 'ls -la /cache/.cache/huggingface/download/*.incomplete 2>/dev/null | tail -6' | indent || dim "  (none / not using local-dir staging)"
    fi

    # --- 6. PVC + Longhorn volume health ---
    section "6. Storage — PVC & Longhorn Volume"
    if [[ -n "$PVC" ]]; then
      kubectl get pvc "$PVC" -n "$CACHE_NS" 2>/dev/null | indent || warn "PVC '${PVC}' not found."
      PV=$(kubectl get pvc "$PVC" -n "$CACHE_NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
      if [[ -n "$PV" ]]; then
        kubectl get volumes.longhorn.io "$PV" -n longhorn-system 2>/dev/null \
          -o custom-columns="VOL:.metadata.name,STATE:.status.state,ROBUST:.status.robustness" | indent \
          || dim "  (Longhorn volume info unavailable)"
      fi
    else
      warn "No PVC bound yet (StorageReady may be False)."
    fi

    # --- 7. HF token presence ---
    section "7. Hugging Face Token"
    HF_ENV=$(kubectl get pods -n "$CACHE_NS" -o jsonpath="{range .items[*]}{.metadata.name}{'='}{.spec.containers[*].env[?(@.name=='HF_TOKEN')].name}{'\n'}{end}" 2>/dev/null \
      | grep "^${C}-cache-download" | grep -c "HF_TOKEN" || true)
    if [[ "${HF_ENV:-0}" -gt 0 ]]; then
      ok "HF_TOKEN is injected into the download pod env."
    else
      warn "HF_TOKEN not detected on the download pod."
      bullet "Public models still download (rate-limited); gated/private models will 401/403."
      fix "Provide a token (e.g. via the cluster HF secret / .env) for gated models and higher rate limits."
    fi

    # --- 8. Downloader image presence (custom image only) ---
    if [[ -n "$DL_IMAGE" ]]; then
      section "8. Custom Downloader Image"
      info "Cache requests image: ${DL_IMAGE}"
      RKE2_CTR="${RKE2_CTR:-/var/lib/rancher/rke2/bin/ctr}"
      RKE2_SOCK="${RKE2_SOCK:-/run/k3s/containerd/containerd.sock}"
      if [[ -x "$RKE2_CTR" && -S "$RKE2_SOCK" ]]; then
        IMG_HIT=$(sudo "$RKE2_CTR" --address "$RKE2_SOCK" -n k8s.io images ls 2>/dev/null \
          | grep -i "${DL_IMAGE%%:*}" || true)
        if [[ -n "$IMG_HIT" ]]; then
          ok "Image present in RKE2 containerd:"; echo "$IMG_HIT" | awk '{print "    "$1}'
        else
          fail "Image '${DL_IMAGE}' NOT found in RKE2 containerd → pods will ImagePullBackOff."
          fix "Build + import: ./scripts/build-gpt-oss-downloader.sh"
        fi
      else
        dim "  (RKE2 ctr/socket not accessible from here — skipping containerd check)"
      fi
    fi

    # --- 9. Recent events for this cache ---
    section "9. Recent Events"
    kubectl get events -n "$CACHE_NS" --sort-by=.lastTimestamp 2>/dev/null \
      | grep -i "${C}" | tail -15 | indent || dim "  (no recent events)"

    # --- 10. Verification checklist (known Xet / GPT-OSS download failure modes) ---
    section "10. Verification Checklist — Symptom & Fix"
    # Helper: print a PASS line, or a FAIL/WARN line followed by Symptom + Fix.
    check_pass() { ok "$1"; }
    check_warn() { warn "$1"; bullet "Symptom: $2"; fix "$3"; }
    check_fail() { fail "$1"; bullet "Symptom: $2"; fix "$3"; }

    # (a) Cache reached Available
    CACHE_STATUS=$(kubectl get aimmodelcache "$C" -n "$CACHE_NS" -o jsonpath='{.status.status}' 2>/dev/null || true)
    case "$CACHE_STATUS" in
      Available) check_pass "Cache status is Available (download complete)." ;;
      Failed)    check_fail "Cache status is Failed." \
                   "Download job failed; status stuck at Failed." \
                   "Review steps 2-4 for the root cause, then delete + recreate the cache." ;;
      *)         check_warn "Cache status is '${CACHE_STATUS:-unknown}' (not yet Available)." \
                   "Download still in progress or blocked." \
                   "Watch step 5 throughput; if zero progress, inspect step 4 logs." ;;
    esac

    # (b) Download Job retry budget not exhausted
    if [[ -n "${JOB_FAILED_COND:-}" && "${JOB_FAILED_COND}" == *BackoffLimitExceeded* ]]; then
      check_fail "Download Job exhausted its backoffLimit." \
        "Job condition 'BackoffLimitExceeded'; operator stops creating new download pods." \
        "Fix the underlying cause below, then delete + recreate the cache to reset the Job."
    else
      check_pass "Download Job retry budget not exhausted."
    fi

    # Custom-image (Xet) caches: verify the image-level prerequisites that the
    # operator's injected env/entrypoint would otherwise defeat.
    if [[ -n "$DL_IMAGE" ]]; then
      # (c) Downloader image present in the cluster runtime
      RKE2_CTR="${RKE2_CTR:-/var/lib/rancher/rke2/bin/ctr}"
      RKE2_SOCK="${RKE2_SOCK:-/run/k3s/containerd/containerd.sock}"
      if [[ -x "$RKE2_CTR" && -S "$RKE2_SOCK" ]]; then
        # Capture (don't use grep -q) to avoid SIGPIPE failing the pipeline under pipefail.
        IMG_PRESENT=$(sudo "$RKE2_CTR" --address "$RKE2_SOCK" -n k8s.io images ls 2>/dev/null \
          | grep -i "${DL_IMAGE%%:*}" || true)
        if [[ -n "$IMG_PRESENT" ]]; then
          check_pass "Downloader image '${DL_IMAGE}' present in RKE2 containerd."
        else
          check_fail "Downloader image '${DL_IMAGE}' missing from RKE2 containerd." \
            "Download pods sit in ImagePullBackOff; no bytes written; looks like a stall." \
            "Build + import: ./scripts/build-gpt-oss-downloader.sh"
        fi
      else
        dim "  (skipping containerd image check — ctr/socket not accessible)"
      fi

      # (d) Deep image check: hf_xet installed in /prod_venv AND Xet survives the
      #     operator-injected HF_HUB_DISABLE_XET=1 (i.e. sitecustomize.py works).
      if command -v docker >/dev/null 2>&1 && docker image inspect "$DL_IMAGE" >/dev/null 2>&1; then
        XET_PROBE=$(docker run --rm -e HF_HUB_DISABLE_XET=1 --entrypoint sh "$DL_IMAGE" -c \
          '/prod_venv/bin/python -c "import os; from huggingface_hub.utils._runtime import is_xet_available; print(\"XET_OK\" if (is_xet_available() and os.environ.get(\"HF_HUB_DISABLE_XET\") is None) else \"XET_OFF\")"' \
          2>/dev/null | tail -1 || true)
        if [[ "$XET_PROBE" == "XET_OK" ]]; then
          check_pass "Image has Xet active in /prod_venv and clears HF_HUB_DISABLE_XET (sitecustomize)."
        else
          check_fail "Image does NOT have Xet active under the operator-injected HF_HUB_DISABLE_XET=1." \
            "Large shards fail with 'file too large ... use hf_xet'; hf_xet installed in wrong env or sitecustomize missing." \
            "Ensure requirements-downloader.txt installs into /prod_venv and scripts/sitecustomize.py is COPY'd in; rebuild."
        fi
      else
        dim "  (skipping deep image Xet probe — image not in local docker)"
      fi

      # (e) Xet engaged at runtime (chunk cache materialized on the volume)
      PROBE_POD="${RUNNING_POD}"
      [[ -z "$PROBE_POD" ]] && PROBE_POD=$(echo "$DL_PODS" | tail -1)
      if [[ -n "$PROBE_POD" ]]; then
        XET_DIR=$(kubectl exec "$PROBE_POD" -n "$CACHE_NS" 2>/dev/null -- sh -c 'ls -d /cache/.hf/xet 2>/dev/null' || true)
        if [[ -n "$XET_DIR" ]]; then
          check_pass "Xet chunk cache present on the volume (/cache/.hf/xet) — Xet was used."
        elif [[ "$CACHE_STATUS" == "Available" ]]; then
          check_pass "Xet chunk cache already cleaned up post-completion (expected for Available cache)."
        else
          check_warn "No /cache/.hf/xet directory observed while still downloading." \
            "Download may be running over plain HTTP (slow) instead of Xet." \
            "Confirm Xet via the deep image probe above; rebuild the image if it reports XET_OFF."
        fi
      fi
    fi

    # (f) HF token injection
    if [[ "${HF_ENV:-0}" -gt 0 ]]; then
      check_pass "HF_TOKEN injected into the download pod."
    else
      check_warn "HF_TOKEN not injected." \
        "Unauthenticated downloads are throttled (~1-2 MB/s) and gated repos return 401/403." \
        "Create the 'hf-token' secret (start.sh does this from .env) so caches inject it via spec.env."
    fi
  done

  echo ""
  info "Recreate a failed cache after fixing the root cause:"
  echo "    kubectl delete aimmodelcache ${CACHE_NAME:-<name>} -n ${CACHE_NS}"
  echo "    kubectl apply -f scripts/poc-caches.yaml   # or a single-resource manifest"
  info "Docs: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html"
  echo ""
  exit 0
fi

# =============================================================================
# Service-level deep-dive
# =============================================================================
if [[ "$#" -lt 1 ]]; then
  error "Missing arguments. Run '$0 --help' for usage."
  exit 1
fi

SERVICE_NAME="$1"
NAMESPACE="${2:-default}"

header "AIM Service Debug: ${SERVICE_NAME}  (ns: ${NAMESPACE})"
echo -e "  ${DIM}Ref: https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html${RESET}"

# Pre-declare globals used in summary
ISVC_NAME=""
PREDICTOR_SVC=""
ISVC_URL=""
ISVC_ADDR=""

# =============================================================================
# STEP 1 — AIMService: Overall Status
# Docs: kubectl get aimservice <name> -n <namespace>
# =============================================================================
section "1. AIMService — Status"
if ! kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" 2>/dev/null; then
  error "AIMService '${SERVICE_NAME}' not found in namespace '${NAMESPACE}'."
  info  "Available services (all namespaces):"
  kubectl get aimservices -A 2>/dev/null | indent || true
  exit 1
fi

STATE=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.state}' 2>/dev/null || echo "")
info "State: ${BOLD}${STATE:-<not set>}${RESET}"

# =============================================================================
# STEP 2 — Conditions: identify blocking condition
# Docs: kubectl get aimservice <name> -n <ns> -o jsonpath='{.status.conditions}' | jq
# Blocked by: Model, Template, RuntimeConfig → Pending
# =============================================================================
section "2. AIMService — Conditions (blocking analysis)"
RAW_CONDITIONS=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")

BLOCK_MODEL=false; BLOCK_TEMPLATE=false; BLOCK_RUNTIME=false
GPU_MISMATCH=false; UNOPTIMIZED_BLOCKED=false

if $HAS_JQ; then
  echo "$RAW_CONDITIONS" | jq -r \
    '.[] | "\(.type)|\(.status)|\(.reason // "-")|\(.message // "")"' 2>/dev/null \
  | while IFS='|' read -r ctype cstatus creason cmsg; do
      case "$ctype" in
        Ready)
          [[ "$cstatus" == "True" ]] \
            && echo -e "  ${GREEN}✓${RESET} ${BOLD}Ready${RESET}: ${cstatus}  (${creason})  ${DIM}${cmsg}${RESET}" \
            || echo -e "  ${RED}✗${RESET} ${BOLD}Ready${RESET}: ${cstatus}  (${creason})  ${DIM}${cmsg}${RESET}"
          ;;
        Failure)
          [[ "$cstatus" == "True" ]] \
            && echo -e "  ${RED}✗${RESET} ${BOLD}Failure${RESET}: ACTIVE  (${creason})  ${cmsg}" \
            || echo -e "  ${GREEN}✓${RESET} Failure: Resolved"
          ;;
        Progressing)
          [[ "$cstatus" == "True" ]] \
            && echo -e "  ${YELLOW}↻${RESET} Progressing: active  ${DIM}${cmsg}${RESET}" \
            || echo -e "  ${GREEN}✓${RESET} Progressing: done"
          ;;
        RuntimeReady)
          [[ "$cstatus" == "True" ]] \
            && echo -e "  ${GREEN}✓${RESET} RuntimeReady  (${creason})  ${DIM}${cmsg}${RESET}" \
            || echo -e "  ${YELLOW}○${RESET} RuntimeReady: ${cstatus}  (${creason})  ${DIM}${cmsg}${RESET}"
          ;;
        Resolved)
          [[ "$cstatus" == "True" ]] \
            && echo -e "  ${GREEN}✓${RESET} Resolved  (${creason})  ${DIM}${cmsg}${RESET}" \
            || echo -e "  ${YELLOW}○${RESET} Resolved: ${cstatus}  (${creason})  ${DIM}${cmsg}${RESET}"
          ;;
        *)
          [[ "$cstatus" == "True" ]] \
            && echo -e "  ${GREEN}✓${RESET} ${ctype}: ${cstatus}  (${creason})  ${DIM}${cmsg}${RESET}" \
            || echo -e "  ${YELLOW}○${RESET} ${ctype}: ${cstatus}  (${creason})  ${DIM}${cmsg}${RESET}"
          ;;
      esac
    done

  # Detect specific blocking patterns from the docs
  MSGS=$(echo "$RAW_CONDITIONS" | jq -r '.[] | .message // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  echo "$MSGS" | grep -qi "model not found\|model.name\|image.*not.*accessible" && BLOCK_MODEL=true
  echo "$MSGS" | grep -qi "no.*template\|template.*not.*found\|no matching template" && BLOCK_TEMPLATE=true
  echo "$MSGS" | grep -qi "runtimeconfig\|runtime config\|runtime.*not found" && BLOCK_RUNTIME=true
  echo "$MSGS" | grep -qi "gpu not in cluster\|notavailable\|required gpu" && GPU_MISMATCH=true
  echo "$MSGS" | grep -qi "unoptimized\|allowunoptimized" && UNOPTIMIZED_BLOCKED=true

  echo ""
  $BLOCK_MODEL        && warn "BLOCKED on: Model — check spec.model.name spelling or spec.model.image accessibility"
  $BLOCK_TEMPLATE     && warn "BLOCKED on: Template — no matching AIMServiceTemplate found (see Step 10)"
  $BLOCK_RUNTIME      && warn "BLOCKED on: RuntimeConfig — missing or invalid RuntimeConfig"
  $GPU_MISMATCH       && { warn "GPU mismatch: required GPU not in cluster"; \
                           fix "Set 'allowUnoptimized: true' in your AIMService spec"; }
  $UNOPTIMIZED_BLOCKED && { warn "Unoptimized profile blocked"; \
                            fix "Add 'allowUnoptimized: true' to AIMService spec"; }
else
  echo "$RAW_CONDITIONS"
fi

# =============================================================================
# STEP 3 — Spec
# =============================================================================
section "3. AIMService — Spec"
if $HAS_JQ; then
  kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '"  Model Name       : \(.spec.model.name // "-")
  Model Image      : \(.spec.model.image // "-")
  Allow Unoptimized: \(.spec.allowUnoptimized // false)
  Replicas         : \(.spec.replicas // 1)
  Template hint    : \(.spec.template.name // "-")
  RuntimeConfig    : \(.spec.runtimeConfig.name // "-")"' 2>/dev/null \
    || kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null | grep -E "model:|image:|allowUnoptimized|replicas|template:|runtimeConfig" | indent
else
  kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null \
    | grep -E "model:|image:|allowUnoptimized|replicas|template:|runtimeConfig" | indent
fi

MODEL_NAME=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.model.name}' 2>/dev/null || true)
MODEL_IMAGE=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.model.image}' 2>/dev/null || true)

# =============================================================================
# STEP 4 — InferenceService
# Docs: kubectl get inferenceservice -n <ns> -l aim.eai.amd.com/service.name=<name>
#       kubectl describe inferenceservice <isvc-name> -n <ns>
# =============================================================================
section "4. InferenceService"
# The operator may label the InferenceService with either the eai or silogen
# service-name key (or the ISVC may simply share the AIMService name).
ISVC_NAME=$(kubectl get inferenceservice -n "$NAMESPACE" \
  -l "aim.eai.amd.com/service.name=$SERVICE_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$ISVC_NAME" ]]; then
  ISVC_NAME=$(kubectl get inferenceservice -n "$NAMESPACE" \
    -l "aim.silogen.ai/service-name=$SERVICE_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "$ISVC_NAME" ]] \
  && kubectl get inferenceservice "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  ISVC_NAME="$SERVICE_NAME"
fi

if [[ -n "$ISVC_NAME" ]]; then
  ok "Found InferenceService: ${ISVC_NAME}"
  kubectl get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" -o wide 2>/dev/null

  ISVC_URL=$(kubectl get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.url}' 2>/dev/null || true)
  ISVC_ADDR=$(kubectl get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.address.url}' 2>/dev/null || true)
  PREDICTOR_SVC=$(kubectl get svc "${ISVC_NAME}-predictor" -n "$NAMESPACE" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

  echo ""
  [[ -n "$ISVC_URL" ]]      && bullet "External URL  : ${ISVC_URL}"
  [[ -n "$ISVC_ADDR" ]]     && bullet "Internal URL  : ${ISVC_ADDR}"
  [[ -n "$PREDICTOR_SVC" ]] && bullet "ClusterIP     : http://${PREDICTOR_SVC}  ← use for direct curl"

  # ── STEP 5: ISVC Conditions ─────────────────────────────────────────────────
  # Docs: kubectl describe inferenceservice <name> shows image pull / resource / PVC errors
  section "5. InferenceService — Conditions"
  if $HAS_JQ; then
    kubectl get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
      | jq -r '.status.conditions[] | "  \(.type): \(.status)  \(.message // "")"' \
      2>/dev/null || true
  else
    kubectl describe inferenceservice "$ISVC_NAME" -n "$NAMESPACE" \
      | grep -A3 "Conditions:\|Ready\|URL:" || true
  fi

  # ── STEP 6: Pods ─────────────────────────────────────────────────────────────
  # Docs: kubectl get pods -l serving.kserve.io/inferenceservice=<isvc-name> -n <ns>
  #       kubectl describe pod <pod-name> -n <ns>
  section "6. Pods — Status"
  kubectl get pods \
    -l "serving.kserve.io/inferenceservice=$ISVC_NAME" \
    -n "$NAMESPACE" -o wide 2>/dev/null \
    || warn "No pods found yet."

  POD_NAME=$(kubectl get pods \
    -l "serving.kserve.io/inferenceservice=$ISVC_NAME" \
    -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$POD_NAME" ]]; then
    section "7. Pod — Resource Requests"
    # Starting issues: Insufficient resources, image pull, PVC
    if $HAS_JQ; then
      kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r '.spec.containers[] |
            "  \(.name)\n" +
            "    CPU   req=\(.resources.requests.cpu//"?") lim=\(.resources.limits.cpu//"?")\n" +
            "    Mem   req=\(.resources.requests.memory//"?") lim=\(.resources.limits.memory//"?")\n" +
            "    GPU   req=\(.resources.requests["amd.com/gpu"]//"0") lim=\(.resources.limits["amd.com/gpu"]//"0")"' \
        2>/dev/null || true
    fi

    # Check imagePullSecrets (Starting issue: image pull errors)
    IPS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.spec.imagePullSecrets[*].name}' 2>/dev/null || true)
    if [[ -n "$IPS" ]]; then
      bullet "imagePullSecrets: ${IPS}"
    else
      dim "  (no imagePullSecrets — using public registry or node credentials)"
    fi

    section "8. Pod — Events (image pull / scheduling / PVC)"
    kubectl describe pod "$POD_NAME" -n "$NAMESPACE" \
      | awk '/^Events:/,0' | head -45 || true

    section "9. Pod — Logs (last 50 lines)"
    kubectl logs "$POD_NAME" -n "$NAMESPACE" --tail=50 2>/dev/null \
      | grep -v "^$" \
      || warn "No logs yet — pod may still be initializing."

    # Check for image pull / OOM in logs
    POD_ERRS=$(kubectl logs "$POD_NAME" -n "$NAMESPACE" --tail=100 2>/dev/null \
      | grep -i "error\|oom\|killed\|failed\|exception\|rocm\|hip" | tail -10 || true)
    if [[ -n "$POD_ERRS" ]]; then
      echo ""
      warn "Notable error patterns in pod logs:"
      echo "$POD_ERRS" | indent
    fi
  else
    warn "No pods scheduled yet — InferenceService awaiting resource allocation."
    warn "Common causes (docs):"
    bullet "Image pull errors — wrong image URL or missing imagePullSecrets"
    bullet "Insufficient resources — not enough GPU, memory, or CPU"
    bullet "PVC not binding — storage class doesn't support ReadWriteMany"
  fi

  # ── STEP 9b: Live Endpoint Check ─────────────────────────────────────────────
  if [[ -n "$PREDICTOR_SVC" ]] && $HAS_CURL; then
    section "9b. Live Endpoint Smoke Test"
    EP="http://${PREDICTOR_SVC}"
    MODEL_ID_LIVE=$(curl -sf --max-time 8 "${EP}/v1/models" 2>/dev/null \
      | jq -r '.data[0].id' 2>/dev/null || echo "")
    if [[ -n "$MODEL_ID_LIVE" ]]; then
      ok "Endpoint ${EP} is live"
      bullet "Model served: ${MODEL_ID_LIVE}"
      SMOKE=$(curl -sf --max-time 20 \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${MODEL_ID_LIVE}\",\"prompt\":\"Hello\",\"max_tokens\":5,\"temperature\":0}" \
        "${EP}/v1/completions" 2>/dev/null \
        | jq -r '.choices[0].text' 2>/dev/null || echo "(no response)")
      bullet "Quick smoke: '${SMOKE}'"
    else
      warn "Endpoint ${EP} did not respond to /v1/models (warming up?)."
    fi
  fi
else
  # No ISVC — service stuck in Pending
  warn "No InferenceService found for '${SERVICE_NAME}'."
  warn "Service is stuck in Pending — no downstream resources created."
  echo ""
  info "Check which condition is blocking (from Step 2 above):"
  echo ""
  echo -e "  ${BOLD}Blocked Component → Likely Cause${RESET}  (source: official docs)"
  echo "  ────────────────────────────────────────────────────────"
  echo "  Model          → check spec.model.name spelling or spec.model.image"
  echo "  Template       → no matching template; verify templates exist and are Ready"
  echo "  RuntimeConfig  → runtime config not found or invalid"
  echo ""
fi

# =============================================================================
# STEP 10 — Template Selection Analysis
# Docs: Templates excluded if:
#   - Status is not Ready (still discovering or failed)
#   - Status is NotAvailable (required GPU not in cluster)
#   - Profile is unoptimized and allowUnoptimized is not set
#   - "Ambiguous selection" → specify template.name explicitly
# =============================================================================
section "10. Template Selection Analysis"
info "Namespace-scoped AIMServiceTemplates (ns: ${NAMESPACE}):"
kubectl get aimservicetemplates -n "$NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.status,MODEL:.spec.model.name" \
  2>/dev/null || warn "No namespace-scoped templates found."

echo ""
info "AIMClusterServiceTemplates (cluster-wide):"
kubectl get aimclusterservicetemplates \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.status,MODEL:.spec.model.name" \
  2>/dev/null || warn "No AIMClusterServiceTemplates found."

# Highlight NotAvailable templates
NOT_AVAIL=$(kubectl get aimservicetemplates -n "$NAMESPACE" --no-headers 2>/dev/null \
  | awk '{print $0}' | grep -i "NotAvailable" || true)
if [[ -n "$NOT_AVAIL" ]]; then
  echo ""
  warn "Templates with NotAvailable status (required GPU not in cluster):"
  echo "$NOT_AVAIL" | indent
  fix "These templates require a GPU not present in this cluster."
  fix "If you need to deploy anyway: set 'allowUnoptimized: true' in the AIMService spec"
  fix "or explicitly name a Ready template via 'spec.template.name'."
fi

# =============================================================================
# STEP 11 — AIMClusterModel
# =============================================================================
section "11. AIMClusterModel"
if [[ -n "$MODEL_NAME" ]]; then
  if $HAS_JQ; then
    kubectl get aimclustermodel "$MODEL_NAME" -o json 2>/dev/null \
      | jq -r '"  Name    : \(.metadata.name)
  Ready   : \(.status.conditions[]? | select(.type=="Ready") | .status)
  Reason  : \(.status.conditions[]? | select(.type=="Ready") | .reason)
  Message : \(.status.conditions[]? | select(.type=="Ready") | .message)"' \
      2>/dev/null || warn "AIMClusterModel '$MODEL_NAME' not found."
  else
    kubectl get aimclustermodel "$MODEL_NAME" 2>/dev/null \
      || warn "AIMClusterModel '$MODEL_NAME' not found."
  fi
elif [[ -n "$MODEL_IMAGE" ]]; then
  info "Deploying from direct image (no AIMClusterModel): ${MODEL_IMAGE}"
else
  warn "No model.name or model.image found in AIMService spec."
fi

# =============================================================================
# STEP 12 — Cache & Artifacts
# Docs: kubectl get aimtemplatecache -n <ns>
#       kubectl get aimartifact -n <ns>
#       kubectl get jobs -l aim.eai.amd.com/artifact=<artifact-name> -n <ns>
#       kubectl logs job/<job-name> -n <ns>
# Common causes: StorageSizeError, download failure, verification failure, PVC RWX
# =============================================================================
section "12. Cache & Artifact Status"
info "AIMTemplateCache:"
kubectl get aimtemplatecache -n "$NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.status,PVC:.spec.pvcName" \
  2>/dev/null | head -10 || warn "No AIMTemplateCache resources found."

echo ""
info "AIMArtifact:"
ARTIFACT_LIST=$(kubectl get aimartifact -n "$NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.status,REASON:.status.reason" \
  2>/dev/null | head -10 || true)
if [[ -n "$ARTIFACT_LIST" ]]; then
  echo "$ARTIFACT_LIST"
else
  warn "No AIMArtifact resources found."
fi

# Check download jobs (docs: artifact download jobs)
echo ""
info "Download Jobs (for artifacts):"
DL_JOBS=$(kubectl get jobs -n "$NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,COMPLETIONS:.status.completionTime,FAILED:.status.failed,ACTIVE:.status.active" \
  2>/dev/null | grep -i "aim\|artifact\|download\|cache" | head -10 || true)
if [[ -n "$DL_JOBS" ]]; then
  echo "$DL_JOBS"
  # Find first failed job and show its logs
  FAILED_JOB=$(kubectl get jobs -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -i "aim\|artifact\|download" \
    | awk '$6 ~ /^[1-9]/ {print $1}' | head -1 || true)
  if [[ -n "$FAILED_JOB" ]]; then
    echo ""
    warn "Failed download job detected: ${FAILED_JOB}"
    info "Last 30 lines of job logs:"
    kubectl logs "job/${FAILED_JOB}" -n "$NAMESPACE" --tail=30 2>/dev/null | indent || true
    echo ""
    info "Common causes (docs):"
    bullet "StorageSizeError — model size not yet discovered; usually resolves automatically"
    bullet "Download failure — network issues, auth errors, or protocol incompatibility"
    bullet "Verification failure — files corrupt after download; downloader retries automatically"
    bullet "PVC binding failure — storage class doesn't support ReadWriteMany (RWX)"
  fi
else
  dim "  No artifact download jobs found."
fi

# =============================================================================
# STEP 13 — Routing (HTTPRoute + Gateway)
# Docs: kubectl get httproute -n <ns>
#       kubectl describe httproute <name> -n <ns>
#       kubectl get gateway -n <gateway-namespace>
# Common causes: gateway not ready, routing.enabled not set, gateway ns mismatch
# =============================================================================
section "13. Routing — HTTPRoute & Gateway"
info "HTTPRoutes for this service:"
HTTP_ROUTES=$(kubectl get httproute -n "$NAMESPACE" \
  -l "aim.eai.amd.com/service.name=$SERVICE_NAME" \
  -o custom-columns="NAME:.metadata.name,HOSTNAMES:.spec.hostnames[*],AGE:.metadata.creationTimestamp" \
  2>/dev/null || true)
if [[ -n "$HTTP_ROUTES" ]]; then
  echo "$HTTP_ROUTES"
  # Describe for condition detail
  ROUTE_NAME=$(kubectl get httproute -n "$NAMESPACE" \
    -l "aim.eai.amd.com/service.name=$SERVICE_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$ROUTE_NAME" ]]; then
    kubectl describe httproute "$ROUTE_NAME" -n "$NAMESPACE" \
      | grep -A3 "Conditions:\|Status:\|Parents:" || true
  fi
else
  warn "No HTTPRoutes found for this service."
  info "Routing may not be enabled. Check: spec.routing.enabled in RuntimeConfig."
fi

echo ""
info "Gateways (all namespaces):"
kubectl get gateway -A \
  -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,CLASS:.spec.gatewayClassName,STATUS:.status.conditions[?(@.type=='Accepted')].reason" \
  2>/dev/null || info "No Gateway resources found (docs: gateway doesn't exist or isn't ready)."

# Warn if no gateway and routes expected
if [[ -n "$HTTP_ROUTES" ]]; then
  GW_COUNT=$(kubectl get gateway -A --no-headers 2>/dev/null | wc -l || echo 0)
  [[ "$GW_COUNT" -eq 0 ]] && warn "HTTPRoutes exist but no Gateway found — routing will not work."
fi

# =============================================================================
# STEP 14 — RuntimeConfig
# Docs: routing.enabled must be set for routing; missing RuntimeConfig → Pending
# =============================================================================
section "14. RuntimeConfig"
RUNTIME_CFG=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.runtimeConfig.name}' 2>/dev/null || true)
if [[ -n "$RUNTIME_CFG" ]]; then
  ok "RuntimeConfig referenced: ${RUNTIME_CFG}"
  kubectl get runtimeconfig "$RUNTIME_CFG" -n "$NAMESPACE" 2>/dev/null \
    || kubectl get runtimeconfig "$RUNTIME_CFG" 2>/dev/null \
    || warn "RuntimeConfig '${RUNTIME_CFG}' not found — this will block service startup!"
else
  dim "  No explicit RuntimeConfig referenced (using defaults)."
fi

# =============================================================================
# STEP 15 — Operator Logs filtered by resource name
# Docs: kubectl logs -n aim-system deployment/aim-engine-controller-manager -f
#       kubectl logs ... | jq 'select(.name == "<resource-name>")'
# =============================================================================
section "15. Operator Logs (filtered by '${SERVICE_NAME}')"
AIM_NS_POD=$(find_aim_operator)
AIM_NS="${AIM_NS_POD%%/*}"; AIM_POD="${AIM_NS_POD##*/}"

if [[ -n "$AIM_POD" ]]; then
  ok "AIM operator: ${AIM_POD} (ns: ${AIM_NS})"
  info "Streaming from official log reference: deployment/aim-engine-controller-manager"
  echo ""

  # Try structured JSON log filtering (jq select(.name == ...) per docs)
  if $HAS_JQ; then
    STRUCTURED=$(kubectl logs "$AIM_POD" -n "$AIM_NS" --tail=500 2>/dev/null \
      | grep "^{" \
      | jq -r "select(.name == \"${SERVICE_NAME}\" or .\"AIMService\" != null) |
          \"[\(.level//\"info\")] \(.ts//.time//\"-\")  \(.msg//.message//\"-\")\"" \
      2>/dev/null || true)
    if [[ -n "$STRUCTURED" ]]; then
      echo "$STRUCTURED" | tail -20
    fi
  fi

  # Fallback: plain grep filtered to this service + error patterns
  echo ""
  info "Keyword-filtered log lines:"
  kubectl logs "$AIM_POD" -n "$AIM_NS" --tail=400 2>/dev/null \
    | grep -i "${SERVICE_NAME}\|error\|warn\|template\|gpu\|pending\|allowUnoptimized\|cache\|artifact\|routing\|fail" \
    | tail -30 \
    || info "No relevant entries found."
else
  warn "AIM Engine controller pod not found."
  info "Expected namespaces: aim-system, kaiwo-system"
  info "Run: kubectl get pods -A | grep -i aim"
fi

# =============================================================================
# Diagnostic Summary
# =============================================================================
header "Diagnostic Summary"

# Refresh state values
STATE=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
READY=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
RUNTIME_READY=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="RuntimeReady")].status}' 2>/dev/null || echo "Unknown")
RESOLVED=$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Resolved")].status}' 2>/dev/null || echo "Unknown")

echo ""
bullet "Service         : ${BOLD}${SERVICE_NAME}${RESET}  (ns: ${NAMESPACE})"
bullet "State           : ${BOLD}${STATE:-<not set>}${RESET}"
bullet "Ready           : ${BOLD}${READY}${RESET}"
bullet "RuntimeReady    : ${BOLD}${RUNTIME_READY}${RESET}"
bullet "Resolved        : ${BOLD}${RESOLVED}${RESET}"
[[ -n "$ISVC_NAME" ]]      && bullet "InferenceService: ${BOLD}${ISVC_NAME}${RESET}"
[[ -n "$PREDICTOR_SVC" ]]  && bullet "ClusterIP       : ${BOLD}http://${PREDICTOR_SVC}${RESET}"
[[ -n "$ISVC_URL" ]]       && bullet "External URL    : ${BOLD}${ISVC_URL}${RESET}"
echo ""

# Status-driven guidance (maps to all 8 official status values)
case "${STATE:-}" in
  Running|"")
    if [[ "$READY" == "True" ]]; then
      ok "Service is RUNNING and ready to serve traffic. ✓"
      [[ -n "$ISVC_URL" ]] && info "Endpoint: ${ISVC_URL}/v1/chat/completions"
      [[ -n "$PREDICTOR_SVC" ]] && info "Direct:   http://${PREDICTOR_SVC}/v1/completions"
    else
      warn "State is Running but Ready condition is not True. Review conditions above."
    fi
    ;;
  Pending)
    warn "Service is PENDING — waiting for upstream dependencies."
    echo ""
    echo -e "  ${BOLD}Check which condition is blocking (from Step 2):${RESET}"
    bullet "Model blocked      → fix spec.model.name or spec.model.image"
    bullet "Template blocked   → check Step 10; templates may be NotAvailable"
    bullet "RuntimeConfig      → check Step 14; config may be missing"
    echo ""
    fix "If template is NotAvailable: add 'allowUnoptimized: true' to spec"
    fix "If ambiguous selection: specify 'spec.template.name' explicitly"
    ;;
  Starting)
    warn "Service is STARTING — InferenceService created, waiting for pods."
    echo ""
    bullet "Image pull in progress (large model — check pod events in Step 8)"
    bullet "Insufficient GPU/memory/CPU — check node allocatable in --gpu"
    bullet "PVC not binding — storage class must support ReadWriteMany (RWX)"
    ;;
  Progressing)
    info "Service is PROGRESSING — resources created, waiting for readiness."
    bullet "InferenceService exists; pod startup may take several minutes."
    bullet "Watch: kubectl get pods -n ${NAMESPACE} -l serving.kserve.io/inferenceservice=${ISVC_NAME:-?} -w"
    ;;
  Degraded)
    error "Service is DEGRADED — partially functional."
    bullet "Check pod events and logs (Steps 8–9 above)"
    bullet "Possible replica failure or intermittent crash-loop"
    ;;
  NotAvailable)
    error "Service is NOT AVAILABLE — required infrastructure not present."
    bullet "Required GPU type not in cluster (check --gpu)"
    fix "Add 'allowUnoptimized: true' or deploy a GPU node of the required type"
    ;;
  Failed)
    error "Service has FAILED — critical failure."
    bullet "Check pod logs and events (Steps 8–9 above)"
    bullet "Check operator logs (Step 15 above)"
    ;;
  *)
    info "State: '${STATE}' — review conditions and logs above."
    ;;
esac

echo ""
info "Full service probe:    $0 --endpoint"
info "Cluster status:        $0 --cluster"
info "Model cache download:  $0 --cache ${SERVICE_NAME}"
info "GPU allocation:        $0 --gpu"
info "All services:          $0 --list"
info "Official docs:         https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html"
echo ""
