#!/usr/bin/env bash
# =============================================================================
# start.sh - Start an AMD Enterprise AI serving endpoint
#
# Deploys the selected AIMService, triggers model caching/download, waits for the
# selected predictor endpoint to become ready, and prints OpenAI-compatible API
# connection details for benchmark.sh and debug.sh.
#
# Usage:
#   ./scripts/start.sh
#   MODEL=llama-3-3-70b ./scripts/start.sh
#   ./scripts/start.sh --model gpt-oss-120b --namespace default
#
# Optional: place MODEL, HF_TOKEN, HUGGING_FACE_HUB_TOKEN, and other overrides
# in scripts/.env. Environment variables and CLI flags still take priority.
#
# Supported MODEL values:
#   llama-3-3-70b      (default)
#   mixtral-8x22b
#   gpt-oss-120b
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

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  info "Loaded environment from: ${ENV_FILE}"
fi

MODEL="${MODEL:-llama-3-3-70b}"
NAMESPACE="${NAMESPACE:-default}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-3600}"
CACHE_WAIT_TIMEOUT_USER_SET="${CACHE_WAIT_TIMEOUT_USER_SET:-${CACHE_WAIT_TIMEOUT:+true}}"
CACHE_WAIT_TIMEOUT="${CACHE_WAIT_TIMEOUT:-1800}"
CACHE_WAIT_TIMEOUT_USER_SET="${CACHE_WAIT_TIMEOUT_USER_SET:-false}"
CACHE_STALL_TIMEOUT_USER_SET="${CACHE_STALL_TIMEOUT_USER_SET:-${CACHE_STALL_TIMEOUT:+true}}"
CACHE_STALL_TIMEOUT="${CACHE_STALL_TIMEOUT:-0}"
CACHE_STALL_TIMEOUT_USER_SET="${CACHE_STALL_TIMEOUT_USER_SET:-false}"
TEMPLATE_CACHE_DELETE_TIMEOUT="${TEMPLATE_CACHE_DELETE_TIMEOUT:-300}"
STOP_WAIT_TIMEOUT="${STOP_WAIT_TIMEOUT:-900}"
POLL_SECONDS="${POLL_SECONDS:-15}"
SKIP_CACHE="${SKIP_CACHE:-false}"
SKIP_SMOKE_TEST="${SKIP_SMOKE_TEST:-false}"
FORCE_CACHE_REFRESH="${FORCE_CACHE_REFRESH:-false}"
STOP_PREVIOUS_MODELS="${STOP_PREVIOUS_MODELS:-true}"
CLEANUP_STALLED_CACHE_POD="${CLEANUP_STALLED_CACHE_POD:-true}"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --model MODEL          Serving model to start (default: ${MODEL})
  --namespace NS         Kubernetes namespace (default: ${NAMESPACE})
  --wait-timeout SEC     Max seconds to wait for readiness (default: ${WAIT_TIMEOUT})
  --cache-timeout SEC    Max seconds to wait for cache readiness (default: ${CACHE_WAIT_TIMEOUT})
  --stop-timeout SEC     Max seconds to wait for old models to stop (default: ${STOP_WAIT_TIMEOUT})
  --skip-cache           Do not create/update AIMModelCache before AIMService
  --skip-smoke-test      Skip /v1/models and /v1/completions checks
  --force-cache-refresh  Re-apply cache and validate Hugging Face access
  --keep-existing-models Do not stop other AIMServices before starting this one
  -h, --help             Show this help message

Environment:
  MODEL                  Same as --model
  NAMESPACE              Same as --namespace
  WAIT_TIMEOUT           Same as --wait-timeout
  CACHE_WAIT_TIMEOUT     Same as --cache-timeout
  STOP_WAIT_TIMEOUT      Same as --stop-timeout
  SKIP_CACHE=true        Same as --skip-cache
  SKIP_SMOKE_TEST=true   Same as --skip-smoke-test
  FORCE_CACHE_REFRESH=true
  STOP_PREVIOUS_MODELS=false
  CLEANUP_STALLED_CACHE_POD=false
  GPT_OSS_MODEL_DOWNLOAD_IMAGE
  HF_TOKEN or HUGGING_FACE_HUB_TOKEN
  scripts/.env      Optional env file loaded before defaults are applied
EOF
}

need_arg() {
  local flag="$1" value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || err "${flag} requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) need_arg "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --namespace|-n) need_arg "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --wait-timeout) need_arg "$1" "${2:-}"; WAIT_TIMEOUT="$2"; shift 2 ;;
    --cache-timeout) need_arg "$1" "${2:-}"; CACHE_WAIT_TIMEOUT="$2"; CACHE_WAIT_TIMEOUT_USER_SET="true"; shift 2 ;;
    --stop-timeout) need_arg "$1" "${2:-}"; STOP_WAIT_TIMEOUT="$2"; shift 2 ;;
    --skip-cache) SKIP_CACHE="true"; shift ;;
    --skip-smoke-test) SKIP_SMOKE_TEST="true"; shift ;;
    --force-cache-refresh) FORCE_CACHE_REFRESH="true"; shift ;;
    --keep-existing-models) STOP_PREVIOUS_MODELS="false"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"
}

require_cmd kubectl
require_cmd jq
require_cmd curl

case "$MODEL" in
  llama-3-3-70b)
    SERVICE_NAME="llama-3-3-70b"
    CLUSTER_MODEL="llama-3-3-70b-model-v11"
    TEMPLATE_CACHE_NAME=""
    CACHE_NAME="llama-3-3-70b-cache"
    CACHE_SIZE="70Gi"
    SOURCE_URI="hf://amd/Llama-3.3-70B-Instruct-FP8-KV"
    SOURCE_NAME="amd/Llama-3.3-70B-Instruct-FP8-KV"
    GPU_COUNT="1"
    MODEL_DOWNLOAD_IMAGE=""
    ;;
  mixtral-8x22b)
    SERVICE_NAME="mixtral-8x22b"
    CLUSTER_MODEL="mixtral-8x22b-model-v11"
    TEMPLATE_CACHE_NAME=""
    CACHE_NAME="mixtral-8x22b-cache"
    CACHE_SIZE="280Gi"
    SOURCE_URI="hf://mistralai/Mixtral-8x22B-Instruct-v0.1"
    SOURCE_NAME="mistralai/Mixtral-8x22B-Instruct-v0.1"
    GPU_COUNT="8"
    MODEL_DOWNLOAD_IMAGE=""
    ;;
  gpt-oss-120b)
    SERVICE_NAME="gpt-oss-120b"
    CLUSTER_MODEL="gpt-oss-120b-model"
    TEMPLATE_CACHE_NAME="gpt-oss-120b-mi355x-lat"
    CACHE_NAME="openai-gpt-oss-120b"
    CACHE_SIZE="240Gi"
    SOURCE_URI="hf://openai/gpt-oss-120b"
    SOURCE_NAME="openai/gpt-oss-120b"
    GPU_COUNT="1"
    [[ "$CACHE_WAIT_TIMEOUT_USER_SET" == "true" ]] || CACHE_WAIT_TIMEOUT="14400"
    [[ "$CACHE_STALL_TIMEOUT_USER_SET" == "true" ]] || CACHE_STALL_TIMEOUT="1800"
    MODEL_DOWNLOAD_IMAGE="${GPT_OSS_MODEL_DOWNLOAD_IMAGE:-gpt-oss-downloader:hf-transfer}"
    ;;
  *)
    err "Unsupported MODEL '${MODEL}'. Supported: llama-3-3-70b, mixtral-8x22b, gpt-oss-120b"
    ;;
esac

apply_supporting_resources() {
  header "Applying AIM model/template resources"
  kubectl apply -f "${SCRIPT_DIR}/bny-custom-templates.yaml"
  kubectl apply -f "${SCRIPT_DIR}/gpt-oss-model.yaml"
  ok "AIMClusterModels and AIMClusterServiceTemplates are applied."
}

other_aimservices() {
  kubectl get aimservices -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg svc "$SERVICE_NAME" '.items[].metadata.name | select(. != $svc)' \
    2>/dev/null || true
}

pods_for_aimservice() {
  local svc="$1"
  kubectl get pods -n "$NAMESPACE" \
    -l "aim.silogen.ai/service-name=${svc}" \
    -o json 2>/dev/null \
    | jq -r '.items[].metadata.name' 2>/dev/null || true
}

gpu_request_summary() {
  kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '
      [.items[] |
        {
          name: .metadata.name,
          phase: .status.phase,
          node: (.spec.nodeName // "-"),
          gpu: ([.spec.containers[].resources.requests["amd.com/gpu"]? // empty] | map(tonumber) | add // 0)
        } |
        select(.gpu > 0) |
        "\(.name) phase=\(.phase) node=\(.node) gpu=\(.gpu)"
      ] | .[]' 2>/dev/null || true
}

wait_for_previous_models_to_stop() {
  local services="$1"
  local start now elapsed remaining svc pods pod_list
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    remaining=""

    for svc in $services; do
      if kubectl get aimservice "$svc" -n "$NAMESPACE" >/dev/null 2>&1; then
        remaining+="${svc} AIMService still deleting; "
      fi

      pods="$(pods_for_aimservice "$svc")"
      if [[ -n "$pods" ]]; then
        pod_list="$(echo "$pods" | paste -sd ',' -)"
        remaining+="${svc} pods still present: ${pod_list}; "
      fi
    done

    if [[ -z "$remaining" ]]; then
      ok "Previous model services have stopped and their pods are gone."
      local gpu_summary
      gpu_summary="$(gpu_request_summary)"
      if [[ -n "$gpu_summary" ]]; then
        info "Current GPU-requesting pods:"
        echo "$gpu_summary" | sed 's/^/  /'
      else
        info "No GPU-requesting pods remain in namespace '${NAMESPACE}'."
      fi
      return
    fi

    if [[ "$elapsed" -gt "$STOP_WAIT_TIMEOUT" ]]; then
      warn "Still waiting on: ${remaining}"
      warn "GPU-requesting pods:"
      gpu_request_summary | sed 's/^/  /' || true
      err "Timed out after ${STOP_WAIT_TIMEOUT}s waiting for previous models to stop."
    fi

    info "Waiting for previous models to stop: ${remaining}elapsed=${elapsed}s"
    sleep "$POLL_SECONDS"
  done
}

stop_previous_models() {
  [[ "$STOP_PREVIOUS_MODELS" == "true" ]] || {
    warn "Keeping existing AIMServices because STOP_PREVIOUS_MODELS=false / --keep-existing-models was set."
    return
  }

  local services
  services="$(other_aimservices)"
  if [[ -z "$services" ]]; then
    ok "No previous AIMServices to stop."
    return
  fi

  header "Stopping previous AIMServices before starting ${SERVICE_NAME}"
  echo "$services" | sed 's/^/  - /'
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    info "Deleting AIMService '${svc}' in namespace '${NAMESPACE}'..."
    kubectl delete aimservice "$svc" -n "$NAMESPACE" --ignore-not-found
  done <<< "$services"

  wait_for_previous_models_to_stop "$services"
}

cache_json() {
  kubectl get aimmodelcache -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -c --arg cache_name "$CACHE_NAME" --arg source_uri "$SOURCE_URI" '
      def readyish:
        ([.status.conditions[]? |
          select(((.type // "") | test("^(Ready|Available|Succeeded|Complete|Completed)$"; "i")) and .status == "True")] | length > 0)
        or ((.status.status // .status.phase // .status.state // "") |
          test("Ready|Available|Succeeded|Complete|Completed"; "i"));
      [.items[] | select(.spec.sourceUri == $source_uri or .metadata.name == $cache_name)]
      | sort_by(if readyish then 0 else 1 end)
      | .[0] // empty
    ' 2>/dev/null || true
}

cache_exists() {
  [[ -n "$(cache_json)" ]]
}

cache_is_ready() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  echo "$json" | jq -e '
    ([.status.conditions[]? |
      select(((.type // "") | test("^(Ready|Available|Succeeded|Complete|Completed)$"; "i")) and .status == "True")] | length > 0)
    or ((.status.status // .status.phase // .status.state // "") |
      test("Ready|Available|Succeeded|Complete|Completed"; "i"))
  ' >/dev/null 2>&1
}

cache_has_failure() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  echo "$json" | jq -e '
    ([.status.conditions[]? |
      select(((.type // "") | test("Fail|Error|Degraded"; "i")) and .status == "True")] | length > 0)
    or ((.status.status // .status.phase // .status.state // "") |
      test("Fail|Error|Degraded"; "i"))
  ' >/dev/null 2>&1
}

cache_status_summary() {
  local json="$1"
  if [[ -z "$json" ]]; then
    echo "not-created"
    return
  fi

  echo "$json" | jq -r '
    def status_text:
      (.status.status // .status.phase // .status.state // "unknown");
    def conds:
      [.status.conditions[]? |
        "\(.type)=\(.status)" +
        (if (.reason // "") != "" then " reason=\(.reason)" else "" end) +
        (if (.message // "") != "" then " message=\(.message)" else "" end)
      ] | join("; ");
    "status=\(status_text)" + (if conds != "" then ", conditions=\(conds)" else "" end)
  ' 2>/dev/null || echo "status=unknown"
}

cache_created_epoch() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  echo "$json" | jq -r '.metadata.creationTimestamp // empty' 2>/dev/null \
    | xargs -r -I{} date -d {} +%s 2>/dev/null \
    || true
}

show_cache_diagnostics() {
  warn "Recent diagnostics for AIMModelCache resources matching '${SOURCE_URI}':"
  kubectl get aimmodelcache -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg source_uri "$SOURCE_URI" '.items[] | select(.spec.sourceUri == $source_uri) | .metadata.name' \
    | while read -r cache; do
        [[ -n "$cache" ]] || continue
        echo "### ${cache}" >&2
        kubectl describe aimmodelcache "$cache" -n "$NAMESPACE" 2>/dev/null | sed -n '/Status:/,$p' || true
      done
  warn "Recent namespace events:"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
}

cache_download_pod() {
  kubectl get pod -n "$NAMESPACE" -l "job-name=${CACHE_NAME}-cache-download" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | awk '$2 == "Running" {name=$1} END {if (name != "") print name}' \
    || true
}

cache_latest_write_epoch() {
  local pod="$1"
  [[ -n "$pod" ]] || return 1

  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c \
    'find /cache -type f -printf "%T@\n" 2>/dev/null | sort -n | tail -1' 2>/dev/null \
    | awk '{printf "%d", $1}' \
    || true
}

show_cache_activity_diagnostics() {
  local pod="$1"
  warn "Cache download activity diagnostics:"
  if [[ -z "$pod" ]]; then
    warn "No running cache download pod found for job '${CACHE_NAME}-cache-download'."
    return
  fi

  kubectl get pod "$pod" -n "$NAMESPACE" -o wide 2>/dev/null || true
  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c \
    'echo "Cache usage:"; du -sh /cache 2>/dev/null || true; echo "Recent cache writes:"; find /cache -type f -printf "%TY-%Tm-%Td %TH:%TM:%TS %s %p\n" 2>/dev/null | sort | tail -20' \
    2>/dev/null || true
  warn "Recent downloader logs:"
  kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=80 2>/dev/null || true
}

cleanup_stalled_cache_pod() {
  local pod="$1"
  [[ "$CLEANUP_STALLED_CACHE_POD" == "true" ]] || return 0
  [[ -n "$pod" ]] || return 0

  warn "Deleting stalled cache download pod '${pod}' so the job can retry from the existing cache PVC."
  kubectl delete pod "$pod" -n "$NAMESPACE" --wait=false 2>/dev/null || true
}

remove_template_cache_if_present() {
  [[ -n "$TEMPLATE_CACHE_NAME" ]] || return 0

  local template_json template_uid delete_start delete_elapsed current_uid current_state
  template_json="$(kubectl get aimtemplatecache "$TEMPLATE_CACHE_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"
  [[ -n "$template_json" ]] || return 0

  template_uid="$(echo "$template_json" | jq -r '.metadata.uid // empty' 2>/dev/null || true)"
  warn "Removing AIMTemplateCache '${TEMPLATE_CACHE_NAME}' so it cannot recreate '${CACHE_NAME}' with the default downloader."
  kubectl delete aimtemplatecache "$TEMPLATE_CACHE_NAME" -n "$NAMESPACE" --ignore-not-found

  delete_start="$(date +%s)"
  while true; do
    template_json="$(kubectl get aimtemplatecache "$TEMPLATE_CACHE_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"
    [[ -n "$template_json" ]] || return 0

    current_uid="$(echo "$template_json" | jq -r '.metadata.uid // empty' 2>/dev/null || true)"
    if [[ -n "$template_uid" && -n "$current_uid" && "$current_uid" != "$template_uid" ]]; then
      current_state="$(echo "$template_json" | jq -r '.status.status // "unknown"' 2>/dev/null || echo "unknown")"
      warn "AIMTemplateCache '${TEMPLATE_CACHE_NAME}' was recreated by the controller with status=${current_state}; continuing with explicit AIMModelCache instead of waiting forever."
      return 0
    fi

    delete_elapsed=$(( $(date +%s) - delete_start ))
    if [[ "$delete_elapsed" -gt "$TEMPLATE_CACHE_DELETE_TIMEOUT" ]]; then
      err "Timed out after ${TEMPLATE_CACHE_DELETE_TIMEOUT}s waiting for AIMTemplateCache '${TEMPLATE_CACHE_NAME}' to delete."
    fi
    info "Waiting for AIMTemplateCache '${TEMPLATE_CACHE_NAME}' to delete..."
    sleep "$POLL_SECONDS"
  done
}

validate_hf_token_for_download() {
  [[ "$SOURCE_URI" == hf://* ]] || return

  header "Validating Hugging Face access"
  local token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
  [[ -n "$token" ]] || err "Download required for ${SOURCE_NAME}, but HF_TOKEN or HUGGING_FACE_HUB_TOKEN is not set."

  info "Checking token access to Hugging Face model: ${SOURCE_NAME}"
  local body http_code
  body="$(mktemp)"
  http_code="$(curl -sS -o "$body" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    "https://huggingface.co/api/models/${SOURCE_NAME}" 2>/dev/null || true)"
  [[ -n "$http_code" ]] || http_code="000"

  case "$http_code" in
    200)
      rm -f "$body"
      ok "Hugging Face token can access ${SOURCE_NAME}."
      ;;
    401)
      rm -f "$body"
      err "Hugging Face token is invalid or expired. Refresh HF_TOKEN/HUGGING_FACE_HUB_TOKEN before downloading ${SOURCE_NAME}."
      ;;
    403|404)
      warn "Hugging Face API returned HTTP ${http_code} for ${SOURCE_NAME}."
      warn "This usually means the token lacks access, the model license is not accepted, or the model name is wrong."
      rm -f "$body"
      err "Cannot download ${SOURCE_NAME} until Hugging Face access is fixed."
      ;;
    000)
      rm -f "$body"
      err "Could not reach Hugging Face to validate token access for ${SOURCE_NAME}."
      ;;
    *)
      warn "Unexpected Hugging Face API response HTTP ${http_code}:"
      sed -n '1,20p' "$body" >&2 || true
      rm -f "$body"
      err "Refusing to start download without confirmed Hugging Face access."
      ;;
  esac
}

apply_explicit_model_cache() {
  [[ -n "$MODEL_DOWNLOAD_IMAGE" ]] || return 1

  header "Creating explicit AIMModelCache"
  local existing_cache existing_name cache_manifest
  existing_cache="$(cache_json)"
  existing_name="$(echo "$existing_cache" | jq -r '.metadata.name // empty' 2>/dev/null || true)"

  if [[ "$FORCE_CACHE_REFRESH" != "true" ]] && cache_is_ready "$existing_cache"; then
    ok "AIMModelCache '${existing_name:-$CACHE_NAME}' is already ready; no download required."
    return 0
  fi

  if [[ "$FORCE_CACHE_REFRESH" != "true" && -n "$existing_name" ]]; then
    local existing_image existing_source
    existing_image="$(echo "$existing_cache" | jq -r '.spec.modelDownloadImage // ""' 2>/dev/null || true)"
    existing_source="$(echo "$existing_cache" | jq -r '.spec.sourceUri // ""' 2>/dev/null || true)"
    if [[ "$existing_name" == "$CACHE_NAME" \
      && "$existing_source" == "$SOURCE_URI" \
      && "$existing_image" == "$MODEL_DOWNLOAD_IMAGE" ]] \
      && ! cache_has_failure "$existing_cache"; then
      ok "AIMModelCache '${CACHE_NAME}' is already downloading with '${MODEL_DOWNLOAD_IMAGE}'; waiting for it to finish."
      wait_for_cache
      return 0
    fi
  fi

  remove_template_cache_if_present

  if [[ -n "$existing_name" ]]; then
    warn "Removing non-ready cache '${existing_name}' before recreating it with ${MODEL_DOWNLOAD_IMAGE}."
    kubectl delete aimmodelcache "$existing_name" -n "$NAMESPACE" --ignore-not-found
    local delete_start delete_elapsed
    delete_start="$(date +%s)"
    while kubectl get aimmodelcache "$existing_name" -n "$NAMESPACE" >/dev/null 2>&1; do
      delete_elapsed=$(( $(date +%s) - delete_start ))
      if [[ "$delete_elapsed" -gt "$CACHE_WAIT_TIMEOUT" ]]; then
        show_cache_diagnostics
        err "Timed out after ${CACHE_WAIT_TIMEOUT}s waiting for old cache '${existing_name}' to delete."
      fi
      info "Waiting for old cache '${existing_name}' to delete..."
      sleep "$POLL_SECONDS"
    done
  fi

  cache_manifest="$(mktemp)"
  cat >"$cache_manifest" <<EOF
apiVersion: aim.silogen.ai/v1alpha1
kind: AIMModelCache
metadata:
  name: ${CACHE_NAME}
  namespace: ${NAMESPACE}
spec:
  runtimeConfigName: default
  size: ${CACHE_SIZE}
  sourceUri: ${SOURCE_URI}
  modelDownloadImage: ${MODEL_DOWNLOAD_IMAGE}
EOF

  kubectl apply -f "$cache_manifest"
  rm -f "$cache_manifest"
  ok "AIMModelCache '${CACHE_NAME}' is configured with downloader image '${MODEL_DOWNLOAD_IMAGE}'."
  wait_for_cache
  return 0
}

wait_for_cache() {
  [[ "$SKIP_CACHE" == "true" ]] && return

  header "Waiting for model cache readiness"
  local start now elapsed json summary
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    json="$(cache_json)"
    summary="$(cache_status_summary "$json")"

    if cache_is_ready "$json"; then
      ok "AIMModelCache '${CACHE_NAME}' is ready; cached model will be used."
      return
    fi

    if cache_has_failure "$json"; then
      show_cache_diagnostics
      err "AIMModelCache '${CACHE_NAME}' reported failure: ${summary}"
    fi

    if [[ "$CACHE_STALL_TIMEOUT" -gt 0 ]] && echo "$summary" | grep -qi 'Progressing'; then
      pod="$(cache_download_pod)"
      latest_write="$(cache_latest_write_epoch "$pod")"
      cache_created="$(cache_created_epoch "$json")"
      if [[ "$cache_created" =~ ^[0-9]+$ && "$latest_write" =~ ^[0-9]+$ && "$latest_write" -ge "$cache_created" ]]; then
        stall_age=$((now - latest_write))
      elif [[ "$cache_created" =~ ^[0-9]+$ ]]; then
        stall_age=$((now - cache_created))
      else
        stall_age=0
      fi

      if [[ "$stall_age" -gt 0 ]]; then
        if [[ "$stall_age" -gt "$CACHE_STALL_TIMEOUT" ]]; then
          show_cache_diagnostics
          show_cache_activity_diagnostics "$pod"
          cleanup_stalled_cache_pod "$pod"
          err "Cache '${CACHE_NAME}' appears stalled: no file writes in ${stall_age}s while status is Progressing."
        fi
      fi
    fi

    [[ "$elapsed" -le "$CACHE_WAIT_TIMEOUT" ]] || {
      show_cache_diagnostics
      err "Timed out after ${CACHE_WAIT_TIMEOUT}s waiting for cache '${CACHE_NAME}'. Last state: ${summary}"
    }

    info "Waiting for cache: ${summary}, elapsed=${elapsed}s"
    sleep "$POLL_SECONDS"
  done
}

apply_cache() {
  [[ "$SKIP_CACHE" == "true" ]] && { warn "Skipping cache pre-check."; return; }

  header "Checking model cache/download requirement"
  local existing_cache
  existing_cache="$(cache_json)"

  if [[ "$FORCE_CACHE_REFRESH" != "true" ]] && cache_is_ready "$existing_cache"; then
    local ready_cache
    ready_cache="$(echo "$existing_cache" | jq -r '.metadata.name // "unknown"' 2>/dev/null || echo "unknown")"
    ok "AIMModelCache '${ready_cache}' is already ready; no download required."
    return
  fi

  if cache_is_ready "$existing_cache"; then
    warn "AIMModelCache for '${SOURCE_URI}' is already ready, but forced validation was requested."
  elif cache_exists; then
    warn "AIMModelCache for '${SOURCE_URI}' exists but is not ready: $(cache_status_summary "$existing_cache")"
    warn "A download may be pending or failed; validating Hugging Face access before continuing."
  else
    info "No cache found for ${SOURCE_NAME}; AIMService cacheModel=true will request a download."
  fi

  validate_hf_token_for_download

  if apply_explicit_model_cache; then
    return
  fi

  ok "Hugging Face access validated. The AIM operator will manage cache creation from the AIMService template."
}

apply_service() {
  header "Starting AIMService"
  local service_manifest
  service_manifest="$(mktemp)"

  cat >"$service_manifest" <<EOF
apiVersion: aim.silogen.ai/v1alpha1
kind: AIMService
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    poc.bny.com/workload: memory-benchmark
spec:
  cacheModel: true
  model:
    ref: ${CLUSTER_MODEL}
  resources:
    limits:
      amd.com/gpu: "${GPU_COUNT}"
    requests:
      amd.com/gpu: "${GPU_COUNT}"
EOF

  kubectl apply -f "$service_manifest"
  rm -f "$service_manifest"
  ok "AIMService '${SERVICE_NAME}' is applied in namespace '${NAMESPACE}'."
}

aimservice_state() {
  kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.status.status // .status.state // "Pending"' 2>/dev/null || true
}

inferenceservice_name() {
  if kubectl get inferenceservice "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "$SERVICE_NAME"
    return
  fi

  kubectl get inferenceservice -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg svc "$SERVICE_NAME" '
      .items[]
      | select(
          .metadata.labels["aim.silogen.ai/service-name"] == $svc
          or .metadata.labels["aim.eai.amd.com/service.name"] == $svc
          or .metadata.name == $svc
        )
      | .metadata.name
    ' 2>/dev/null | head -1 || true
}

inferenceservice_ready() {
  local isvc="$1"
  kubectl get inferenceservice "$isvc" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -e '.status.conditions[]? | select(.type=="Ready" and .status=="True")' >/dev/null
}

aimservice_has_failure() {
  local json
  json="$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  echo "$json" | jq -e '
    ([.status.conditions[]? |
      select(((.type // "") | test("Fail|Error|Degraded"; "i")) and .status == "True")] | length > 0)
    or ((.status.status // .status.phase // .status.state // "") |
      test("Fail|Error|Degraded|NotAvailable"; "i"))
  ' >/dev/null 2>&1
}

aimservice_summary() {
  local json
  json="$(kubectl get aimservice "$SERVICE_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    echo "not-created"
    return
  fi

  echo "$json" | jq -r '
    def status_text:
      (.status.status // .status.phase // .status.state // "unknown");
    def conds:
      [.status.conditions[]? |
        "\(.type)=\(.status)" +
        (if (.reason // "") != "" then " reason=\(.reason)" else "" end) +
        (if (.message // "") != "" then " message=\(.message)" else "" end)
      ] | join("; ");
    "status=\(status_text)" + (if conds != "" then ", conditions=\(conds)" else "" end)
  ' 2>/dev/null || echo "status=unknown"
}

inferenceservice_summary() {
  local isvc="$1"
  [[ -n "$isvc" ]] || { echo "not-created"; return; }

  kubectl get inferenceservice "$isvc" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '
      def conds:
        [.status.conditions[]? |
          "\(.type)=\(.status)" +
          (if (.reason // "") != "" then " reason=\(.reason)" else "" end) +
          (if (.message // "") != "" then " message=\(.message)" else "" end)
        ] | join("; ");
      if conds != "" then conds else "conditions=unknown" end
    ' 2>/dev/null || echo "conditions=unknown"
}

show_service_diagnostics() {
  local isvc
  isvc="$(inferenceservice_name)"
  warn "AIMService diagnostics:"
  kubectl describe aimservice "$SERVICE_NAME" -n "$NAMESPACE" 2>/dev/null | sed -n '/Status:/,$p' || true
  if [[ -n "$isvc" ]]; then
    warn "InferenceService diagnostics for '${isvc}':"
    kubectl describe inferenceservice "$isvc" -n "$NAMESPACE" 2>/dev/null | sed -n '/Status:/,$p' || true
    warn "Recent serving pods:"
    kubectl get pods -n "$NAMESPACE" -l "serving.kserve.io/inferenceservice=${isvc}" -o wide 2>/dev/null || true
  fi
  warn "Recent namespace events:"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
}

predictor_ip() {
  local isvc="$1"
  kubectl get svc "${isvc}-predictor" -n "$NAMESPACE" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

wait_for_endpoint() {
  header "Waiting for active serving endpoint (2-60min depending on download size)"
  local start now elapsed state isvc ip isvc_summary cache_state
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "$elapsed" -gt "$WAIT_TIMEOUT" ]]; then
      show_service_diagnostics
      err "Timed out after ${WAIT_TIMEOUT}s waiting for '${SERVICE_NAME}' to become ready."
    fi

    state="$(aimservice_state)"
    isvc="$(inferenceservice_name)"
    isvc_summary="$(inferenceservice_summary "$isvc")"
    cache_state="$(cache_json)"

    if cache_has_failure "$cache_state"; then
      show_cache_diagnostics
      err "Model cache for '${SOURCE_URI}' failed while waiting for '${SERVICE_NAME}' to become ready: $(cache_status_summary "$cache_state")"
    fi

    if aimservice_has_failure; then
      show_service_diagnostics
      err "AIMService '${SERVICE_NAME}' reported a failure: $(aimservice_summary)"
    fi

    if [[ -n "$isvc" ]] && inferenceservice_ready "$isvc"; then
      ip="$(predictor_ip "$isvc")"
      if [[ -n "$ip" ]]; then
        TARGET_URL="http://${ip}"
        INFERENCE_SERVICE="$isvc"
        ok "InferenceService '${isvc}' is ready: ${TARGET_URL}"
        return
      fi
    fi

    info "Waiting: AIMService=${state:-unknown}, InferenceService=${isvc:-not-created}, ${isvc_summary}, elapsed=${elapsed}s"
    sleep "$POLL_SECONDS"
  done
}

smoke_test_endpoint() {
  [[ "$SKIP_SMOKE_TEST" == "true" ]] && { warn "Skipping endpoint smoke test."; return; }

  header "Smoke testing OpenAI-compatible API"
  local models_resp completion_resp
  models_resp="$(curl -sf --max-time 20 "${TARGET_URL}/v1/models" 2>/dev/null || true)"
  [[ -n "$models_resp" ]] || err "Endpoint did not respond to ${TARGET_URL}/v1/models"

  MODEL_ID="$(echo "$models_resp" | jq -r '.data[0].id // empty' 2>/dev/null || true)"
  [[ -n "$MODEL_ID" ]] || err "Could not detect model ID from ${TARGET_URL}/v1/models"
  ok "Model ID: ${MODEL_ID}"

  completion_resp="$(curl -sf --max-time 60 "${TARGET_URL}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_ID}\",\"prompt\":\"What is 2+2?\",\"max_tokens\":8,\"temperature\":0}" \
    2>/dev/null || true)"
  [[ -n "$completion_resp" ]] || err "Endpoint did not respond to /v1/completions"
  ok "Completion smoke test succeeded."
}

print_next_steps() {
  header "Serving endpoint ready"
  cat <<EOF
MODEL=${MODEL}
SERVICE_NAME=${SERVICE_NAME}
INFERENCE_SERVICE=${INFERENCE_SERVICE}
TARGET_URL=${TARGET_URL}
MODEL_ID=${MODEL_ID:-}

Run benchmark:
  TARGET_URL="${TARGET_URL}" MODEL_ID="${MODEL_ID:-}" ${REPO_ROOT}/scripts/benchmark.sh

Run endpoint debug:
  ${REPO_ROOT}/scripts/debug.sh --endpoint "${TARGET_URL}"

Run service debug:
  ${REPO_ROOT}/scripts/debug.sh "${SERVICE_NAME}" "${NAMESPACE}"
EOF
}

use_existing_endpoint_if_ready() {
  local isvc ip models_resp served_id

  isvc="$(inferenceservice_name)"
  [[ -n "$isvc" ]] || return 1
  inferenceservice_ready "$isvc" || return 1

  ip="$(predictor_ip "$isvc")"
  [[ -n "$ip" ]] || return 1
  TARGET_URL="http://${ip}"
  INFERENCE_SERVICE="$isvc"

  models_resp="$(curl -fsS --max-time 10 "${TARGET_URL}/v1/models" 2>/dev/null || true)"
  [[ -n "$models_resp" ]] || return 1

  served_id="$(echo "$models_resp" | jq -r '.data[0].id // empty' 2>/dev/null || true)"
  [[ -n "$served_id" ]] || return 1

  if [[ "$served_id" != "$SOURCE_NAME" ]]; then
    warn "Existing endpoint is ready, but serves '${served_id}' instead of '${SOURCE_NAME}'; continuing with startup."
    return 1
  fi

  MODEL_ID="$served_id"
  ok "AIMService '${SERVICE_NAME}' is already running and serving '${MODEL_ID}' at ${TARGET_URL}."
  print_next_steps
  exit 0
}

header "AMD Enterprise AI endpoint startup"
info "Selected model: ${MODEL}"
info "Namespace: ${NAMESPACE}"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || err "Namespace '${NAMESPACE}' does not exist."

apply_supporting_resources
use_existing_endpoint_if_ready || true
apply_cache
stop_previous_models
apply_service
wait_for_cache
wait_for_endpoint
smoke_test_endpoint
print_next_steps
