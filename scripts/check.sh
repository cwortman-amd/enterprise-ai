#!/usr/bin/env bash
# =============================================================================
# check.sh - Sanity check AMD Enterprise AI model serving
#
# Starts each selected model through start.sh, verifies the active served
# model through /v1/models, then sends a small OpenAI-compatible chat request.
#
# Usage:
#   ./scripts/check.sh
#   ./scripts/check.sh --model gpt-oss-120b
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

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  info "Loaded environment from: ${ENV_FILE}"
fi

MODELS_CSV="${MODELS:-llama-3-3-70b,mixtral-8x22b,gpt-oss-120b}"
NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/results/eai-check}"
CHAT_TIMEOUT="${CHAT_TIMEOUT:-90}"
PROMPT="${PROMPT:-Reply with one short sentence confirming the model is ready.}"
STOP_ON_FAIL="${STOP_ON_FAIL:-false}"
KEEP_EXISTING_MODELS="${KEEP_EXISTING_MODELS:-false}"
START_EXTRA_ARGS=()

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --model MODEL           Single model to check, alias for --models MODEL
  --models CSV             Comma-separated model list (default: ${MODELS_CSV})
  --namespace NS           Kubernetes namespace (default: ${NAMESPACE})
  --output-dir DIR         Directory for logs and summary (default: ${OUTPUT_DIR})
  --prompt TEXT            Chat prompt to send to each model
  --chat-timeout SEC       curl timeout for chat request (default: ${CHAT_TIMEOUT})
  --stop-on-fail           Stop after first failed model
  --keep-existing-models   Pass through to start.sh
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) need_arg "$1" "${2:-}"; MODELS_CSV="$2"; shift 2 ;;
    --models) need_arg "$1" "${2:-}"; MODELS_CSV="$2"; shift 2 ;;
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
[[ -x "$START_SCRIPT" ]] || err "start.sh is not executable: ${START_SCRIPT}"

if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="${REPO_ROOT}/${OUTPUT_DIR}"
fi
mkdir -p "$OUTPUT_DIR"

if [[ "$KEEP_EXISTING_MODELS" == "true" ]]; then
  START_EXTRA_ARGS+=(--keep-existing-models)
fi

IFS=',' read -r -a MODELS <<< "$MODELS_CSV"
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

extract_target_url() {
  local log_file="$1"
  awk -F= '/^TARGET_URL=/{print $2}' "$log_file" | tail -1
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

header "AMD Enterprise AI sanity check"
info "Models: ${MODELS_CSV}"
info "Namespace: ${NAMESPACE}"
info "Output directory: ${OUTPUT_DIR}"

FAILURES=0

for raw_model in "${MODELS[@]}"; do
  model="${raw_model//[[:space:]]/}"
  [[ -n "$model" ]] || continue

  header "Checking model: ${model}"
  start_time="$(date +%s)"
  model_safe="${model//[^A-Za-z0-9_.-]/_}"
  start_log="${OUTPUT_DIR}/${model_safe}.start.log"
  models_json="${OUTPUT_DIR}/${model_safe}.models.json"
  chat_json="${OUTPUT_DIR}/${model_safe}.chat.json"
  target_url=""
  served_model_id=""

  info "Launching ${model} via start.sh..."
  if ! "$START_SCRIPT" --model "$model" --namespace "$NAMESPACE" "${START_EXTRA_ARGS[@]}" 2>&1 | tee "$start_log"; then
    elapsed=$(( $(date +%s) - start_time ))
    note="start failed; AIMService status=$(status_for_model "$model")"
    fail "${model}: ${note}"
    record_result "$model" "FAIL" "" "" "$elapsed" "$note"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
    continue
  fi

  target_url="$(extract_target_url "$start_log")"
  if [[ -z "$target_url" ]]; then
    elapsed=$(( $(date +%s) - start_time ))
    note="start completed but TARGET_URL was not found in output"
    fail "${model}: ${note}"
    record_result "$model" "FAIL" "" "" "$elapsed" "$note"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
    continue
  fi

  info "Double-checking active model from ${target_url}/v1/models ..."
  if ! curl -sf --max-time 20 "${target_url}/v1/models" > "$models_json"; then
    elapsed=$(( $(date +%s) - start_time ))
    note="/v1/models did not respond"
    fail "${model}: ${note}"
    record_result "$model" "FAIL" "$target_url" "" "$elapsed" "$note"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
    continue
  fi

  served_model_id="$(jq -r '.data[0].id // empty' "$models_json" 2>/dev/null || true)"
  if [[ -z "$served_model_id" ]]; then
    elapsed=$(( $(date +%s) - start_time ))
    note="/v1/models responded but no model ID was found"
    fail "${model}: ${note}"
    record_result "$model" "FAIL" "$target_url" "" "$elapsed" "$note"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
    continue
  fi
  ok "Active served model ID: ${served_model_id}"

  info "Sending chat sanity request..."
  if ! run_chat_sanity "$target_url" "$served_model_id" "$chat_json"; then
    elapsed=$(( $(date +%s) - start_time ))
    note="/v1/chat/completions failed"
    fail "${model}: ${note}"
    record_result "$model" "FAIL" "$target_url" "$served_model_id" "$elapsed" "$note"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
    continue
  fi

  chat_text="$(jq -r '.choices[0].message.content // .choices[0].text // empty' "$chat_json" 2>/dev/null || true)"
  if [[ -z "$chat_text" ]]; then
    elapsed=$(( $(date +%s) - start_time ))
    note="chat response returned no text"
    fail "${model}: ${note}"
    record_result "$model" "FAIL" "$target_url" "$served_model_id" "$elapsed" "$note"
    FAILURES=$((FAILURES + 1))
    [[ "$STOP_ON_FAIL" == "true" ]] && break
    continue
  fi

  elapsed=$(( $(date +%s) - start_time ))
  ok "${model}: chat sanity passed in ${elapsed}s"
  echo "  Response: ${chat_text}"
  record_result "$model" "PASS" "$target_url" "$served_model_id" "$elapsed" "chat response received"
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
