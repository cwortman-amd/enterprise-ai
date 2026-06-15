#!/usr/bin/env bash
# =============================================================================
# deploy.sh - Start an AMD Enterprise AI serving endpoint (raw AIM track)
#
# Deploys a model from the deploy/ directory as a plain Kubernetes Deployment +
# Service using the AIM container image directly (no AIM operator). Models are
# auto-discovered from the deploy/ directory structure:
#
#   deploy/<model>/deployment.yaml      (required: Deployment [+ PVC])
#   deploy/<model>/service.yaml         (required: Service)
#   deploy/<model>/profile-configmap.yaml  (optional: AIM custom profile)
#
# Any new deploy/<model>/ directory containing a deployment.yaml is picked up
# automatically — no edits to this script required.
#
# Usage:
#   ./scripts/deploy.sh --list
#   ./scripts/deploy.sh --model gpt-oss-120b
#   MODEL=llama-3-3-70b ./scripts/deploy.sh
#   ./scripts/deploy.sh --model mixtral-8x22b --namespace default
#
# Optional: place MODEL, HF_TOKEN, HUGGING_FACE_HUB_TOKEN, NAMESPACE in
# scripts/.env. Environment variables and CLI flags take priority.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
err()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
header(){ echo ""; echo -e "${BOLD}$*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_ROOT}/deploy}"

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  info "Loaded environment from: ${ENV_FILE}"
fi

MODEL="${MODEL:-}"
NAMESPACE="${NAMESPACE:-default}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-3600}"
POLL_SECONDS="${POLL_SECONDS:-15}"
STOP_WAIT_TIMEOUT="${STOP_WAIT_TIMEOUT:-300}"
STOP_PREVIOUS_MODELS="${STOP_PREVIOUS_MODELS:-true}"
SKIP_SECRET="${SKIP_SECRET:-false}"
DO_WAIT="${DO_WAIT:-true}"
DO_VERIFY="${DO_VERIFY:-true}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-600}"
VERIFY_CHAT_TIMEOUT="${VERIFY_CHAT_TIMEOUT:-120}"
VERIFY_PROMPT="${VERIFY_PROMPT:-Reply with one short sentence confirming you are ready.}"
ACTION="apply"            # apply | delete
PURGE_PVC="false"         # only relevant for --delete
HF_TOKEN_SECRET="${HF_TOKEN_SECRET:-hf-token}"

# -----------------------------------------------------------------------------
# Model discovery
# -----------------------------------------------------------------------------
discover_models() {
  local d
  for d in "${DEPLOY_DIR}"/*/; do
    [[ -f "${d}deployment.yaml" ]] && basename "${d%/}"
  done
}

list_models() {
  header "Available models in ${DEPLOY_DIR}"
  local m found=0
  while read -r m; do
    [[ -n "$m" ]] || continue
    found=1
    if [[ -f "${DEPLOY_DIR}/${m}/profile-configmap.yaml" ]]; then
      echo "  - ${m}  (custom profile)"
    else
      echo "  - ${m}"
    fi
  done < <(discover_models)
  [[ "$found" -eq 1 ]] || echo "  (none found — add deploy/<model>/deployment.yaml)"
}

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --model MODEL          Model to deploy (a directory under deploy/)
  --namespace NS         Kubernetes namespace (default: ${NAMESPACE})
  --list                 List auto-discovered models and exit
  --keep-existing        Do not stop other running models (raw or operator) first
  --stop-timeout SEC     Max seconds to wait for freed GPUs (default: ${STOP_WAIT_TIMEOUT})
  --skip-secret          Do not create/update the hf-token secret
  --no-wait              Apply manifests without waiting for rollout
  --wait-timeout SEC     Max seconds to wait for rollout (default: ${WAIT_TIMEOUT})
  --no-verify            Skip the post-rollout /v1/models + chat sanity check
  --verify-timeout SEC   Max seconds to wait for the endpoint to serve (default: ${VERIFY_TIMEOUT})
  --delete               Tear down the model (Deployment + Service; keeps PVC)
  --purge                With --delete, also delete the model-cache PVC(s)
  --help                 Show this help and the model list

Examples:
  ./scripts/deploy.sh --list
  ./scripts/deploy.sh --model gpt-oss-120b
  ./scripts/deploy.sh --model llama-3-3-70b --delete
EOF
  echo ""
  list_models
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)         MODEL="$2";              shift 2 ;;
    --namespace)     NAMESPACE="$2";          shift 2 ;;
    --list)          list_models; exit 0 ;;
    --keep-existing) STOP_PREVIOUS_MODELS="false"; shift ;;
    --stop-timeout)  STOP_WAIT_TIMEOUT="$2";   shift 2 ;;
    --skip-secret)   SKIP_SECRET="true";      shift ;;
    --no-wait)       DO_WAIT="false";         shift ;;
    --wait-timeout)  WAIT_TIMEOUT="$2";       shift 2 ;;
    --no-verify)     DO_VERIFY="false";       shift ;;
    --verify-timeout) VERIFY_TIMEOUT="$2";    shift 2 ;;
    --delete)        ACTION="delete";         shift ;;
    --purge)         PURGE_PVC="true";        shift ;;
    --help|-h)       usage; exit 0 ;;
    *) err "Unknown argument: $1 (run with --help)" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"; }
require_cmd kubectl
require_cmd jq

[[ -d "$DEPLOY_DIR" ]] || err "Deploy directory not found: ${DEPLOY_DIR}"

if [[ -z "$MODEL" ]]; then
  warn "No --model specified."
  usage
  exit 1
fi

MODEL_DIR="${DEPLOY_DIR}/${MODEL}"
if [[ ! -f "${MODEL_DIR}/deployment.yaml" ]]; then
  warn "Model '${MODEL}' not found (no ${MODEL_DIR}/deployment.yaml)."
  list_models
  exit 1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Print metadata.name for every resource of the given kind across a model dir.
resources_of_kind() { # dir kind
  kubectl apply -f "$1" --dry-run=client -o json 2>/dev/null \
    | jq -r --arg k "$2" '(if .kind=="List" then .items else [.] end)[]
        | select(.kind==$k) | .metadata.name'
}

needs_hf_token() {  # dir — true if any manifest references the hf-token secret
  grep -rqs "${HF_TOKEN_SECRET}" "$1" 2>/dev/null
}

ensure_hf_token_secret() {
  [[ "$SKIP_SECRET" == "true" ]] && return 0
  needs_hf_token "$MODEL_DIR" || return 0
  local token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
  if [[ -z "$token" ]]; then
    warn "Model references secret '${HF_TOKEN_SECRET}' but no HF_TOKEN is set."
    warn "Gated model downloads will fail unless the model is already cached."
    return 0
  fi
  info "Ensuring Hugging Face token secret '${HF_TOKEN_SECRET}' in '${NAMESPACE}'."
  kubectl create secret generic "$HF_TOKEN_SECRET" -n "$NAMESPACE" \
    --from-literal=token="$token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Secret '${HF_TOKEN_SECRET}' is in place."
}

# Count pods (Running/Pending) that request amd.com/gpu and do NOT belong to the
# model we are about to deploy. These are what hold GPUs we need to free.
gpu_holding_other_pods() {
  kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg m "${MODEL}-aim" '[.items[]
        | select(.status.phase=="Running" or .status.phase=="Pending")
        | select([.spec.containers[].resources.requests["amd.com/gpu"]//empty] | length > 0)
        | select((.metadata.labels.app // "") != $m)
        | .metadata.name] | length' 2>/dev/null || echo 0
}

# Stop other deploy-track models (Deployment + Service only; PVCs are kept so
# cached weights survive). Frees GPUs before starting the selected model.
stop_other_models() {
  [[ "$STOP_PREVIOUS_MODELS" == "true" ]] || { warn "Keeping existing models (--keep-existing)."; return 0; }
  local other dir name
  while read -r other; do
    [[ -n "$other" && "$other" != "$MODEL" ]] || continue
    dir="${DEPLOY_DIR}/${other}"
    # Only act if something for this model is actually running.
    while read -r name; do
      [[ -n "$name" ]] || continue
      if kubectl get deployment "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
        info "Stopping other model '${other}': deleting deployment/${name}."
        kubectl delete deployment "$name" -n "$NAMESPACE" --ignore-not-found >/dev/null
      fi
    done < <(resources_of_kind "${dir}/deployment.yaml" Deployment)
    while read -r name; do
      [[ -n "$name" ]] || continue
      kubectl delete service "$name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    done < <(resources_of_kind "${dir}/service.yaml" Service)
  done < <(discover_models)
}

# True if the AIM operator CRD is installed on this cluster.
operator_present() {
  kubectl get crd aimservices.aim.silogen.ai >/dev/null 2>&1
}

# Stop operator-track models. The AIM operator runs models as AIMServices, which
# create an InferenceService + predictor pod that holds GPUs. deploy.sh requests
# all GPUs on the node, so any running AIMService must be stopped first. Deleting
# the AIMService cascades to its InferenceService and predictor pods (PVC-backed
# AIMModelCaches are left intact). Mirrors start.sh's stop-previous behavior.
stop_operator_models() {
  [[ "$STOP_PREVIOUS_MODELS" == "true" ]] || return 0
  operator_present || return 0
  local svc found=0
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    found=1
    info "Stopping operator-track AIMService '${svc}' to free GPUs."
    kubectl delete aimservice "$svc" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  done < <(kubectl get aimservices -n "$NAMESPACE" -o name 2>/dev/null | sed 's#.*/##')
  [[ "$found" -eq 1 ]] && ok "Operator-track AIMService(s) stopped."
  return 0
}

# Block until previously-running GPU pods have actually released their GPUs.
# Pod deletion (and AIMService finalizers) can lag, so without this the new pod
# silently sits Pending with "Insufficient amd.com/gpu".
wait_for_gpu_release() {
  [[ "$STOP_PREVIOUS_MODELS" == "true" ]] || return 0
  local waited=0 busy
  busy="$(gpu_holding_other_pods)"; busy="${busy:-0}"
  [[ "$busy" -eq 0 ]] && return 0
  info "Waiting for GPUs to be released by ${busy} other pod(s) (timeout ${STOP_WAIT_TIMEOUT}s)..."
  while :; do
    busy="$(gpu_holding_other_pods)"; busy="${busy:-0}"
    [[ "$busy" -eq 0 ]] && { ok "GPUs released."; return 0; }
    if [[ "$waited" -ge "$STOP_WAIT_TIMEOUT" ]]; then
      warn "Still ${busy} GPU-holding pod(s) after ${STOP_WAIT_TIMEOUT}s; the new pod may stay Pending."
      kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null \
        | rg -i 'gpu|predictor|aim' || true
      return 0
    fi
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

wait_for_rollout() {
  [[ "$DO_WAIT" == "true" ]] || { warn "Skipping rollout wait (--no-wait)."; return 0; }
  local name
  while read -r name; do
    [[ -n "$name" ]] || continue
    info "Waiting for deployment/${name} to become available (timeout ${WAIT_TIMEOUT}s)..."
    if kubectl rollout status "deployment/${name}" -n "$NAMESPACE" \
         --timeout="${WAIT_TIMEOUT}s"; then
      ok "deployment/${name} is rolled out."
    else
      warn "deployment/${name} did not become ready within ${WAIT_TIMEOUT}s."
      kubectl get pods -n "$NAMESPACE" -l "app=${name}" -o wide || true
      err "Rollout failed for '${name}'. Inspect pod logs/events above."
    fi
  done < <(resources_of_kind "${MODEL_DIR}/deployment.yaml" Deployment)
}

# Resolve the first usable Service ClusterIP base URL (http://ip:port) for the model.
resolve_service_endpoint() {
  local svc ip port
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    ip="$(kubectl get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    port="$(kubectl get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
    if [[ -n "$ip" && "$ip" != "None" ]]; then
      echo "http://${ip}:${port:-80}"
      return 0
    fi
  done < <(resources_of_kind "${MODEL_DIR}/service.yaml" Service)
  return 1
}

# Block until the model actually serves: /v1/models reports a model AND a chat
# (or completion) request returns non-empty text. This is what makes deploy.sh
# "not done" until the endpoint is genuinely usable.
verify_serving() {
  [[ "$DO_VERIFY" == "true" ]] || { warn "Skipping serving verification (--no-verify)."; return 0; }
  [[ "$DO_WAIT" == "true" ]]   || { warn "Skipping serving verification (--no-wait)."; return 0; }
  command -v curl >/dev/null 2>&1 || err "curl is required to verify serving. Re-run with --no-verify to skip."

  local base
  base="$(resolve_service_endpoint || true)"
  [[ -n "$base" ]] || err "Could not resolve a Service ClusterIP to verify '${MODEL}'."

  header "Verifying serving endpoint"
  info "Endpoint: ${base}"

  # 1. Wait for /v1/models to report a served model ID.
  local waited=0 model_id=""
  info "Waiting for ${base}/v1/models to report a model (timeout ${VERIFY_TIMEOUT}s)..."
  while :; do
    model_id="$(curl -sf -m 10 "${base}/v1/models" 2>/dev/null | jq -r '.data[0].id // empty' 2>/dev/null || true)"
    [[ -n "$model_id" ]] && break
    if [[ "$waited" -ge "$VERIFY_TIMEOUT" ]]; then
      err "Endpoint ${base}/v1/models did not report a model within ${VERIFY_TIMEOUT}s. If cluster IPs are not routable from here, port-forward and curl manually, or re-run with --no-verify."
    fi
    sleep "$POLL_SECONDS"; waited=$((waited + POLL_SECONDS))
  done
  ok "Served model ID: ${model_id}"

  # 2. Demonstrate a real chat response (fall back to /v1/completions).
  info "Sending chat sanity request..."
  local resp text payload
  payload="$(jq -nc --arg m "$model_id" --arg p "$VERIFY_PROMPT" \
    '{model:$m, messages:[{role:"user", content:$p}], max_tokens:64, temperature:0}')"
  resp="$(curl -sf -m "$VERIFY_CHAT_TIMEOUT" "${base}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"
  text="$(echo "$resp" | jq -r '.choices[0].message.content // .choices[0].text // empty' 2>/dev/null || true)"

  if [[ -z "$text" ]]; then
    info "Chat endpoint returned no text; trying /v1/completions..."
    payload="$(jq -nc --arg m "$model_id" --arg p "$VERIFY_PROMPT" \
      '{model:$m, prompt:$p, max_tokens:64, temperature:0}')"
    resp="$(curl -sf -m "$VERIFY_CHAT_TIMEOUT" "${base}/v1/completions" \
      -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"
    text="$(echo "$resp" | jq -r '.choices[0].text // empty' 2>/dev/null || true)"
  fi

  [[ -n "$text" ]] || err "Chat verification failed — no text returned from ${base}. Last response: ${resp:-<empty>}"
  ok "Chat response received:"
  echo "  ${text}"
}

print_access_info() {
  header "Access"
  local svc
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    echo "  Service: ${svc} (namespace ${NAMESPACE})"
    echo "    kubectl port-forward service/${svc} 8000:80 -n ${NAMESPACE}"
  done < <(resources_of_kind "${MODEL_DIR}/service.yaml" Service)
  cat <<EOF

  Then query the OpenAI-compatible API:
    curl http://localhost:8000/v1/models
    curl http://localhost:8000/v1/completions \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"<model-id>","prompt":"Once upon a time,","max_tokens":50}'
EOF
}

# -----------------------------------------------------------------------------
# Delete path
# -----------------------------------------------------------------------------
delete_model() {
  header "Deleting deploy-track model '${MODEL}' from namespace '${NAMESPACE}'"
  local name
  while read -r name; do
    [[ -n "$name" ]] || continue
    kubectl delete deployment "$name" -n "$NAMESPACE" --ignore-not-found
  done < <(resources_of_kind "${MODEL_DIR}/deployment.yaml" Deployment)
  while read -r name; do
    [[ -n "$name" ]] || continue
    kubectl delete service "$name" -n "$NAMESPACE" --ignore-not-found
  done < <(resources_of_kind "${MODEL_DIR}/service.yaml" Service)

  if [[ "$PURGE_PVC" == "true" ]]; then
    while read -r name; do
      [[ -n "$name" ]] || continue
      warn "Purging PVC '${name}' (cached weights will be lost)."
      kubectl delete pvc "$name" -n "$NAMESPACE" --ignore-not-found
    done < <(resources_of_kind "${MODEL_DIR}/deployment.yaml" PersistentVolumeClaim)
  else
    info "Keeping model-cache PVC(s). Use --purge to remove them."
  fi
  ok "Model '${MODEL}' torn down."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [[ "$ACTION" == "delete" ]]; then
  delete_model
  exit 0
fi

header "Deploying '${MODEL}' (raw AIM track) into namespace '${NAMESPACE}'"
info "Manifests: ${MODEL_DIR}"

ensure_hf_token_secret
stop_other_models
stop_operator_models
wait_for_gpu_release

header "Applying manifests"
kubectl apply -f "${MODEL_DIR}/" -n "$NAMESPACE"
ok "Applied manifests for '${MODEL}'."

wait_for_rollout
verify_serving
print_access_info

header "Done"
ok "Model '${MODEL}' deployed and verified serving via the raw AIM track."
