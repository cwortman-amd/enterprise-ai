#!/usr/bin/env bash
# =============================================================================
# check.sh - Quick chat sanity check against the served model
#
# Auto-detects the serving endpoint (raw deploy.sh track preferred, operator
# start.sh track as fallback), then makes two curl calls and prints the output:
#   1. GET  /v1/models            - what model is being served
#   2. POST /v1/chat/completions  - a small chat request
#
# It does NOT deploy, start, or stop anything. Pass --url to target a specific
# endpoint (e.g. http://localhost:8000) and skip auto-detection.
#
# Usage:
#   ./scripts/check.sh
#   ./scripts/check.sh --url http://localhost:8000
#   ./scripts/check.sh --namespace default --prompt "Say hello in French"
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
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

NAMESPACE="${NAMESPACE:-default}"
TARGET_URL="${TARGET_URL:-}"
MODEL_ID="${MODEL_ID:-}"
PROMPT="${PROMPT:-Reply with one short sentence confirming you are ready.}"
CHAT_TIMEOUT="${CHAT_TIMEOUT:-90}"

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --url, --target-url URL   Endpoint to check (skips auto-detection)
  --namespace, -n NS        Namespace for auto-detection (default: ${NAMESPACE})
  --model-id MODEL          Model ID for the chat request (default: from /v1/models)
  --prompt TEXT             Chat prompt to send
  --chat-timeout SEC        curl timeout for the chat request (default: ${CHAT_TIMEOUT})
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url|--target-url) TARGET_URL="$2"; shift 2 ;;
    --namespace|-n)     NAMESPACE="$2";  shift 2 ;;
    --model-id)         MODEL_ID="$2";   shift 2 ;;
    --prompt)           PROMPT="$2";     shift 2 ;;
    --chat-timeout)     CHAT_TIMEOUT="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) err "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

command -v curl >/dev/null 2>&1 || err "Required command not found: curl"
command -v jq   >/dev/null 2>&1 || err "Required command not found: jq"

# Auto-detect the served endpoint, preferring the raw deploy.sh track (an
# available "<model>-aim" Deployment reached via its Service ClusterIP), then
# the operator start.sh track (a Ready InferenceService predictor ClusterIP).
detect_endpoint() {
  command -v kubectl >/dev/null 2>&1 || err "kubectl not found; pass --url to target an endpoint."

  local dep ip port
  dep=$(kubectl get deploy -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[]
        | select((.metadata.name | endswith("-aim")) and ((.status.availableReplicas // 0) >= 1))
        | .metadata.name' 2>/dev/null | head -n1 || true)
  if [[ -n "$dep" ]]; then
    ip=$(kubectl get svc "$dep" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    port=$(kubectl get svc "$dep" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
    if [[ -n "$ip" && "$ip" != "None" ]]; then echo "http://${ip}:${port:-80}"; return 0; fi
  fi

  local isvc
  isvc=$(kubectl get inferenceservice -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' \
    2>/dev/null | head -n1 || true)
  if [[ -n "$isvc" ]]; then
    ip=$(kubectl get svc "${isvc}-predictor" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [[ -n "$ip" && "$ip" != "None" ]]; then echo "http://${ip}"; return 0; fi
  fi
  return 1
}

header "AMD Enterprise AI sanity check"
if [[ -z "$TARGET_URL" ]]; then
  info "Auto-detecting served endpoint (namespace: ${NAMESPACE}) ..."
  TARGET_URL="$(detect_endpoint || true)"
  [[ -n "$TARGET_URL" ]] || err "No served model found in '${NAMESPACE}'. Deploy one (scripts/deploy.sh --model <name>) or pass --url."
fi
info "Endpoint: ${TARGET_URL}"

# 1. GET /v1/models -----------------------------------------------------------
header "GET ${TARGET_URL}/v1/models"
models_resp="$(curl -sf --max-time 20 "${TARGET_URL}/v1/models")" \
  || err "/v1/models did not respond."
echo "$models_resp" | jq '.' 2>/dev/null || echo "$models_resp"

if [[ -z "$MODEL_ID" ]]; then
  MODEL_ID="$(echo "$models_resp" | jq -r '.data[0].id // empty' 2>/dev/null || true)"
fi
[[ -n "$MODEL_ID" ]] || err "Could not determine model ID from /v1/models (pass --model-id)."
ok "Served model ID: ${MODEL_ID}"

# 2. POST /v1/chat/completions ------------------------------------------------
header "POST ${TARGET_URL}/v1/chat/completions"
payload="$(jq -nc --arg m "$MODEL_ID" --arg p "$PROMPT" \
  '{model:$m, messages:[{role:"user", content:$p}], max_tokens:64, temperature:0}')"
chat_resp="$(curl -sf --max-time "$CHAT_TIMEOUT" "${TARGET_URL}/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "$payload")" \
  || err "/v1/chat/completions failed."
echo "$chat_resp" | jq '.' 2>/dev/null || echo "$chat_resp"

chat_text="$(echo "$chat_resp" | jq -r '.choices[0].message.content // .choices[0].text // empty' 2>/dev/null || true)"
[[ -n "$chat_text" ]] || err "Chat response contained no text."

header "Result"
ok "Chat response: ${chat_text}"
