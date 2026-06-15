#!/usr/bin/env bash
# =============================================================================
# check.sh - Sanity check AMD Enterprise AI model serving
#
# Default (no --model/--models): auto-detects the model(s) currently being
# served and validates them — verifies /v1/models and sends a small
# OpenAI-compatible chat request. It does NOT deploy anything.
#
# Detection prefers the raw deploy.sh track (an available "<model>-aim"
# Deployment, reached via its Service ClusterIP), then the operator start.sh
# track (a Ready InferenceService predictor).
#
# With --model/--models: ensures each named model is served before validating.
# It prefers deploy.sh (raw track) and only falls back to start.sh (operator)
# when the model has no deploy/<model>/ manifest.
#
# Usage:
#   ./scripts/check.sh                                   # validate the served model
#   ./scripts/check.sh --model gpt-oss-120b              # ensure + validate
#   ./scripts/check.sh --models llama-3-3-70b,gpt-oss-120b
#   ./scripts/check.sh --stop-on-fail
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
err()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET}  $*" >&2; }
header(){ echo ""; echo -e "${BOLD}$*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
START_SCRIPT="${SCRIPT_DIR}/start.sh"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy.sh"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_ROOT}/deploy}"

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  info "Loaded environment from: ${ENV_FILE}"
fi

# No fixed default model list: with no --model/--models the served model is
# auto-detected. MODELS env still works (treated as an explicit selection).
MODELS_CSV="${MODELS:-}"
NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/results/eai-check}"
CHAT_TIMEOUT="${CHAT_TIMEOUT:-90}"
PROMPT="${PROMPT:-Reply with one short sentence confirming the model is ready.}"
STOP_ON_FAIL="${STOP_ON_FAIL:-false}"
KEEP_EXISTING_MODELS="${KEEP_EXISTING_MODELS:-false}"
START_EXTRA_ARGS=()
DEPLOY_EXTRA_ARGS=()

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --model MODEL           Single model to ensure + check, alias for --models MODEL
  --models CSV             Comma-separated model list to ensure + check
                           (when omitted, the currently-served model is auto-detected)
  --namespace NS           Kubernetes namespace (default: ${NAMESPACE})
  --output-dir DIR         Directory for logs and summary (default: ${OUTPUT_DIR})
  --prompt TEXT            Chat prompt to send to each model
  --chat-timeout SEC       curl timeout for chat request (default: ${CHAT_TIMEOUT})
  --stop-on-fail           Stop after first failed model
  --keep-existing-models   Pass through to deploy.sh/start.sh when ensuring a model
  -h, --help               Show this help message

Environment:
  MODELS                   Same as --models
  NAMESPACE                Same as --namespace
  OUTPUT_DIR               Same as --output-dir
  CHAT_TIMEOUT             Same as --chat-timeout
  PROMPT                   Same as --prompt
  STOP_ON_FAIL=true
  KEEP_EXISTING_MODELS=true
  HF_TOKEN or HUGGING_FACE_HUB_TOKEN are read by start.sh when needed
EOF
}

need_arg() {
  local flag="$1" value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || err "${flag} requires a value."
}

MODELS_SPECIFIED="false"
[[ -n "$MODELS_CSV" ]] && MODELS_SPECIFIED="true"   # MODELS env counts as explicit

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) need_arg "$1" "${2:-}"; MODELS_CSV="$2"; MODELS_SPECIFIED="true"; shift 2 ;;
    --models) need_arg "$1" "${2:-}"; MODELS_CSV="$2"; MODELS_SPECIFIED="true"; shift 2 ;;
    --namespace|-n) need_arg "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --output-dir) need_arg "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
    --prompt) need_arg "$1" "${2:-}"; PROMPT="$2"; shift 2 ;;
    --chat-timeout) need_arg "$1" "${2:-}"; CHAT_TIMEOUT="$2"; shift 2 ;;
    --stop-on-fail) STOP_ON_FAIL="true"; shift ;;
    --keep-existing-models) KEEP_EXISTING_MODELS="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

command -v curl >/dev/null 2>&1 || err "Required command not found: curl"
command -v jq >/dev/null 2>&1 || err "Required command not found: jq"
command -v kubectl >/dev/null 2>&1 || err "Required command not found: kubectl"

if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="${REPO_ROOT}/${OUTPUT_DIR}"
fi
mkdir -p "$OUTPUT_DIR"

if [[ "$KEEP_EXISTING_MODELS" == "true" ]]; then
  START_EXTRA_ARGS+=(--keep-existing-models)
  DEPLOY_EXTRA_ARGS+=(--keep-existing)
fi

SUMMARY_FILE="${OUTPUT_DIR}/check.$(date '+%Y%m%d_%H%M%S').summary.tsv"
LATEST_SUMMARY="${OUTPUT_DIR}/check.latest.summary.tsv"

printf "model\tstatus\ttarget_url\tserved_model_id\telapsed_seconds\tnote\n" > "$SUMMARY_FILE"

json_escape() {
  jq -Rn --arg v "$1" '$v'
}

record_result() {
  local model="$1" status="$2" target_url="$3" served_model_id="$4" elapsed="$5" note="$6"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$model" "$status" "$target_url" "$served_model_id" "$elapsed" "$note" >> "$SUMMARY_FILE"
}

run_chat_sanity() {
  local target_url="$1" served_model_id="$2" response_file="$3"
  local prompt_json model_json payload

  prompt_json="$(json_escape "$PROMPT")"
  model_json="$(json_escape "$served_model_id")"
  payload="$(cat <<EOF
{
  "model": ${model_json},
  "messages": [
    {"role": "user", "content": ${prompt_json}}
  ],
  "max_tokens": 64,
  "temperature": 0
}
EOF
)"

  curl -sf --max-time "$CHAT_TIMEOUT" "${target_url}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload" > "$response_file"
}

status_for_model() {
  local model="$1"
  kubectl get aimservice "$model" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.status.status // .status.state // "unknown"' 2>/dev/null || echo "not-created"
}

# Endpoint (ClusterIP) for a raw deploy.sh model, only if its Deployment is
# available. Service is named "<model>-aim" and exposes the API on its port.
raw_endpoint_for() {
  local model="$1" dep="${1}-aim" ip port avail
  avail="$(kubectl get deploy "$dep" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  [[ "${avail:-0}" -ge 1 ]] || return 1
  ip="$(kubectl get svc "$dep" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ -n "$ip" && "$ip" != "None" ]] || return 1
  port="$(kubectl get svc "$dep" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  echo "http://${ip}:${port:-80}"
}

# Endpoint (predictor ClusterIP) for an operator start.sh model, only if its
# InferenceService is Ready.
operator_endpoint_for() {
  local model="$1" ready ip
  ready="$(kubectl get inferenceservice "$model" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '[.status.conditions[]? | select(.type=="Ready") | .status][0] // empty' 2>/dev/null || true)"
  [[ "$ready" == "True" ]] || return 1
  ip="$(kubectl get svc "${model}-predictor" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ -n "$ip" && "$ip" != "None" ]] || return 1
  echo "http://${ip}"
}

# Resolve a model's serving endpoint, preferring the raw deploy.sh track.
endpoint_for() {
  local model="$1" ep
  if ep="$(raw_endpoint_for "$model")"; then echo "$ep"; return 0; fi
  if ep="$(operator_endpoint_for "$model")"; then echo "$ep"; return 0; fi
  return 1
}

# All currently-served models, raw track first, de-duplicated (preserves order).
discover_served_models() {
  {
    kubectl get deploy -n "$NAMESPACE" -o json 2>/dev/null \
      | jq -r '.items[]
          | select((.metadata.name | endswith("-aim")) and ((.status.availableReplicas // 0) >= 1))
          | (.metadata.name | sub("-aim$"; ""))' 2>/dev/null || true
    kubectl get inferenceservice -n "$NAMESPACE" -o json 2>/dev/null \
      | jq -r '.items[]
          | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))
          | .metadata.name' 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

# Ensure a named model is served. Prefers deploy.sh (raw track); falls back to
# start.sh (operator) only when there is no deploy/<model>/ manifest. No-op if
# the model is already served.
ensure_served() {
  local model="$1" log="$2"
  if endpoint_for "$model" >/dev/null 2>&1; then
    info "${model}: already served — validating existing endpoint."
    return 0
  fi
  if [[ -f "${DEPLOY_DIR}/${model}/deployment.yaml" ]]; then
    info "${model}: not running — deploying via deploy.sh (raw track)."
    [[ -x "$DEPLOY_SCRIPT" ]] || { warn "deploy.sh not executable: ${DEPLOY_SCRIPT}"; return 1; }
    "$DEPLOY_SCRIPT" --model "$model" --namespace "$NAMESPACE" "${DEPLOY_EXTRA_ARGS[@]}" 2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
  fi
  warn "${model}: no deploy/${model}/ manifest — falling back to start.sh (operator track)."
  [[ -x "$START_SCRIPT" ]] || { warn "start.sh not executable: ${START_SCRIPT}"; return 1; }
  "$START_SCRIPT" --model "$model" --namespace "$NAMESPACE" "${START_EXTRA_ARGS[@]}" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

# Validate one model end-to-end. Echoes live progress. On success sets
# TARGET_URL / SERVED_ID / CHAT_TEXT and returns 0; on the first failing step
# sets NOTE (and TARGET_URL/SERVED_ID as far as resolved) and returns 1.
check_one_model() {
  local model="$1"
  TARGET_URL=""; SERVED_ID=""; CHAT_TEXT=""; NOTE=""
  local safe="${model//[^A-Za-z0-9_.-]/_}"
  local models_json="${OUTPUT_DIR}/${safe}.models.json"
  local chat_json="${OUTPUT_DIR}/${safe}.chat.json"

  # Only bring a model up when explicitly requested; default mode never deploys.
  if [[ "$MODELS_SPECIFIED" == "true" ]]; then
    if ! ensure_served "$model" "${OUTPUT_DIR}/${safe}.start.log"; then
      NOTE="ensure failed; AIMService status=$(status_for_model "$model")"; return 1
    fi
  fi

  TARGET_URL="$(endpoint_for "$model" || true)"
  [[ -n "$TARGET_URL" ]] || { NOTE="model is not served (no available deploy.sh Deployment or Ready InferenceService)"; return 1; }
  info "Endpoint: ${TARGET_URL}"

  info "Double-checking active model from ${TARGET_URL}/v1/models ..."
  curl -sf --max-time 20 "${TARGET_URL}/v1/models" > "$models_json" 2>/dev/null \
    || { NOTE="/v1/models did not respond"; return 1; }
  SERVED_ID="$(jq -r '.data[0].id // empty' "$models_json" 2>/dev/null || true)"
  [[ -n "$SERVED_ID" ]] || { NOTE="/v1/models responded but no model ID was found"; return 1; }
  ok "Active served model ID: ${SERVED_ID}"

  info "Sending chat sanity request..."
  run_chat_sanity "$TARGET_URL" "$SERVED_ID" "$chat_json" 2>/dev/null \
    || { NOTE="/v1/chat/completions failed"; return 1; }
  CHAT_TEXT="$(jq -r '.choices[0].message.content // .choices[0].text // empty' "$chat_json" 2>/dev/null || true)"
  [[ -n "$CHAT_TEXT" ]] || { NOTE="chat response returned no text"; return 1; }
  return 0
}

header "AMD Enterprise AI sanity check"
info "Namespace: ${NAMESPACE}"
info "Output directory: ${OUTPUT_DIR}"

# Resolve the model list. With no explicit selection, validate whatever is
# currently being served (raw deploy.sh track preferred, operator as fallback).
if [[ "$MODELS_SPECIFIED" == "true" ]]; then
  IFS=',' read -r -a MODELS <<< "$MODELS_CSV"
  info "Mode: ensure + validate specified model(s): ${MODELS_CSV}"
else
  mapfile -t MODELS < <(discover_served_models)
  if [[ "${#MODELS[@]}" -eq 0 ]]; then
    err "No served model found in namespace '${NAMESPACE}'. Deploy one first (e.g. 'scripts/deploy.sh --model gpt-oss-120b') or pass --model."
  fi
  info "Mode: validate currently-served model(s): ${MODELS[*]}"
fi

FAILURES=0

for raw_model in "${MODELS[@]}"; do
  model="${raw_model//[[:space:]]/}"
  [[ -n "$model" ]] || continue

  header "Checking model: ${model}"
  start_time="$(date +%s)"

  if check_one_model "$model"; then
    elapsed=$(( $(date +%s) - start_time ))
    ok "${model}: chat sanity passed in ${elapsed}s"
    echo "  Response: ${CHAT_TEXT}"
    record_result "$model" "PASS" "$TARGET_URL" "$SERVED_ID" "$elapsed" "chat response received"
  else
    elapsed=$(( $(date +%s) - start_time ))
    fail "${model}: ${NOTE}"
    record_result "$model" "FAIL" "$TARGET_URL" "$SERVED_ID" "$elapsed" "$NOTE"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
  fi
done

cp "$SUMMARY_FILE" "$LATEST_SUMMARY"

header "Sanity check summary"
column -t -s $'\t' "$SUMMARY_FILE" 2>/dev/null || cat "$SUMMARY_FILE"
echo ""
info "Summary: ${SUMMARY_FILE}"
info "Latest summary: ${LATEST_SUMMARY}"

if [[ "$FAILURES" -gt 0 ]]; then
  err "${FAILURES} model sanity check(s) failed."
fi

ok "All selected model sanity checks passed."
