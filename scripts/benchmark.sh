#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — AMD Enterprise AI Benchmarking Automation
#
# Automates:
#   1. Performance sweep  : inference-perf concurrency sweep across use cases
#   2. Accuracy evaluation: lm-evaluation-harness (MMLU + GSM8K via vLLM)
#
# Usage:
#   bash scripts/benchmark.sh [OPTIONS]
#
# Options:
#   --mode perf|accuracy|all   What to run (default: all)
#   --target-url URL           Override endpoint URL (skips auto-detect)
#   --port-forward SVC         kubectl port-forward to Service SVC for the run
#                              (e.g. the raw deploy.sh service gpt-oss-120b-aim),
#                              then auto-set TARGET_URL and clean up on exit.
#   --namespace NS             Namespace for --port-forward (default: default)
#   --local-port PORT          Local port for --port-forward (default: 8000)
#   --model-id MODEL           Override model ID (skips curl auto-detect)
#   --tokenizer NAME           HF tokenizer for synthetic data (default: model ID).
#                              Must match the served model so prompt token counts
#                              are accurate; use "gpt2" only as an offline fallback.
#   --tensor-parallel N        Tensor parallel size for lm_eval (default: 8)
#   --max-model-len N          Max context length for lm_eval (default: 16384)
#   --output-dir DIR           Results output directory (default: results/)
#   --help                     Show this help message
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
MODE="all"
TARGET_URL="${TARGET_URL:-}"
PORT_FORWARD="${PORT_FORWARD:-}"
PF_NAMESPACE="${PF_NAMESPACE:-default}"
PF_LOCAL_PORT="${PF_LOCAL_PORT:-8000}"
PF_REMOTE_PORT="${PF_REMOTE_PORT:-80}"
PF_WAIT_TIMEOUT="${PF_WAIT_TIMEOUT:-180}"
PF_PID=""
# Serving pod identity (captured during endpoint detection) so the accuracy
# phase can stream the server's own logs and surface the real error behind a 500.
SERVING_NAMESPACE=""
SERVING_POD_SELECTOR=""
POD_LOG_PID=""
MODEL_ID="${MODEL_ID:-}"
TOKENIZER="${TOKENIZER:-}"
TENSOR_PARALLEL=8
MAX_MODEL_LEN=16384
OUTPUT_DIR="results"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load optional scripts/.env (provides HF_TOKEN, MODEL_ID, etc.) before defaults.
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { echo "[$(date '+%H:%M:%S')] INFO  $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN  $*" >&2; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR $*" >&2; exit 1; }
sep()  { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)            MODE="$2";            shift 2 ;;
    --target-url)      TARGET_URL="$2";      shift 2 ;;
    --port-forward)    PORT_FORWARD="$2";    shift 2 ;;
    --namespace)       PF_NAMESPACE="$2";    shift 2 ;;
    --local-port)      PF_LOCAL_PORT="$2";   shift 2 ;;
    --model-id)        MODEL_ID="$2";        shift 2 ;;
    --tokenizer)       TOKENIZER="$2";       shift 2 ;;
    --tensor-parallel) TENSOR_PARALLEL="$2"; shift 2 ;;
    --max-model-len)   MAX_MODEL_LEN="$2";   shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2";      shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *) err "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

[[ "$MODE" =~ ^(perf|accuracy|all)$ ]] \
  || err "Invalid --mode '$MODE'. Must be perf, accuracy, or all."

if [ -n "${PORT_FORWARD}" ] && [ -n "${TARGET_URL}" ]; then
  err "--port-forward and --target-url are mutually exclusive. Pick one."
fi

# Ensure OUTPUT_DIR is an absolute path
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="${WORKDIR}/${OUTPUT_DIR}"
fi

# Datetime stamp shared by the log file and any per-run outputs
DT="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${OUTPUT_DIR}/benchmark.${DT}.log"
LOG_LATEST="${OUTPUT_DIR}/benchmark.latest.log"

# -----------------------------------------------------------------------------
# Port-forward lifecycle (raw deploy.sh track convenience)
# -----------------------------------------------------------------------------
stop_port_forward() {
  if [ -n "${PF_PID}" ] && kill -0 "${PF_PID}" 2>/dev/null; then
    info "Stopping port-forward (pid ${PF_PID})"
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  PF_PID=""
}

# Stream the serving pod(s) logs to a file in the background. Lets the accuracy
# phase recover the real server-side traceback behind an HTTP 500 (e.g. NaN
# logprobs → "Out of range float values are not JSON compliant").
start_pod_log_capture() {
  local out="$1"
  POD_LOG_PID=""
  command -v kubectl >/dev/null 2>&1 || return 0
  if [ -z "${SERVING_POD_SELECTOR}" ]; then
    warn "Serving pod is unknown (custom --target-url?); server-side log capture disabled."
    return 0
  fi
  info "Streaming server pod logs (-l ${SERVING_POD_SELECTOR} -n ${SERVING_NAMESPACE}) → ${out}"
  # --tail=5 keeps the pre-roll small; the stream then captures everything that
  # happens during the eval, including the traceback printed when a request 500s.
  kubectl logs -f --tail=5 --timestamps --prefix --max-log-requests 10 \
    -l "${SERVING_POD_SELECTOR}" -n "${SERVING_NAMESPACE}" > "${out}" 2>&1 &
  POD_LOG_PID=$!
}

stop_pod_log_capture() {
  if [ -n "${POD_LOG_PID}" ] && kill -0 "${POD_LOG_PID}" 2>/dev/null; then
    kill "${POD_LOG_PID}" 2>/dev/null || true
    wait "${POD_LOG_PID}" 2>/dev/null || true
  fi
  POD_LOG_PID=""
}

# Single cleanup hook for every background helper this script may start.
cleanup() {
  stop_pod_log_capture
  stop_port_forward
}
trap cleanup EXIT INT TERM

start_port_forward() {
  command -v kubectl >/dev/null 2>&1 \
    || err "--port-forward requires kubectl on PATH."

  kubectl get svc "${PORT_FORWARD}" -n "${PF_NAMESPACE}" >/dev/null 2>&1 \
    || err "Service '${PORT_FORWARD}' not found in namespace '${PF_NAMESPACE}'. Run 'scripts/deploy.sh --list' to see deployed services."

  # Reach the serving pod for log capture via the Service's own pod selector.
  SERVING_NAMESPACE="${PF_NAMESPACE}"
  SERVING_POD_SELECTOR=$(kubectl get svc "${PORT_FORWARD}" -n "${PF_NAMESPACE}" -o json 2>/dev/null \
    | jq -r 'if (.spec.selector // {}) == {} then "" else (.spec.selector | to_entries | map("\(.key)=\(.value)") | join(",")) end' 2>/dev/null || true)

  info "Starting port-forward: svc/${PORT_FORWARD} (${PF_NAMESPACE}) localhost:${PF_LOCAL_PORT} -> ${PF_REMOTE_PORT}"
  kubectl port-forward "service/${PORT_FORWARD}" \
    "${PF_LOCAL_PORT}:${PF_REMOTE_PORT}" -n "${PF_NAMESPACE}" >/dev/null 2>&1 &
  PF_PID=$!

  local url="http://localhost:${PF_LOCAL_PORT}"
  local waited=0
  info "Waiting for endpoint to become ready (timeout ${PF_WAIT_TIMEOUT}s) ..."
  until curl -sf "${url}/v1/models" >/dev/null 2>&1; do
    if ! kill -0 "${PF_PID}" 2>/dev/null; then
      err "port-forward process exited unexpectedly. Is the pod running? Try 'scripts/deploy.sh --list'."
    fi
    if [ "${waited}" -ge "${PF_WAIT_TIMEOUT}" ]; then
      err "Endpoint ${url}/v1/models not ready after ${PF_WAIT_TIMEOUT}s. Check pod status / readiness."
    fi
    sleep 3
    waited=$((waited + 3))
  done

  TARGET_URL="${url}"
  info "Port-forward ready: ${TARGET_URL}"
}

# -----------------------------------------------------------------------------
# Endpoint auto-detection
# -----------------------------------------------------------------------------
detect_endpoint() {
  if [ -n "${TARGET_URL}" ]; then
    info "Using provided TARGET_URL: ${TARGET_URL}"
    return
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    TARGET_URL="http://localhost:8000"
    info "kubectl not found; using Docker endpoint: ${TARGET_URL}"
    return
  fi

  info "Auto-detecting serving endpoint (deploy.sh raw track preferred)..."

  # 1. Raw deploy.sh (AIM) track takes precedence: an available "<model>-aim"
  #    Deployment created by scripts/deploy.sh. Target its Service ClusterIP
  #    directly (like the operator path) rather than a kubectl port-forward
  #    tunnel — port-forward drops connections under the long, high-concurrency
  #    accuracy eval (lm_eval), causing ServerDisconnectedError. Use the
  #    explicit --port-forward flag when the ClusterIP is not routable from here
  #    (e.g. a remote kubeconfig).
  local aim_name
  aim_name=$(kubectl get deploy -n "${PF_NAMESPACE}" -o json 2>/dev/null \
    | jq -r '.items[]
        | select((.metadata.name | endswith("-aim")) and ((.status.availableReplicas // 0) >= 1))
        | .metadata.name' 2>/dev/null | head -n1 || true)
  if [ -n "${aim_name}" ]; then
    local aim_ip aim_port
    aim_ip=$(kubectl get svc "${aim_name}" -n "${PF_NAMESPACE}" \
      -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    aim_port=$(kubectl get svc "${aim_name}" -n "${PF_NAMESPACE}" \
      -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
    if [ -n "${aim_ip}" ] && [ "${aim_ip}" != "None" ]; then
      TARGET_URL="http://${aim_ip}:${aim_port:-80}"
      SERVING_NAMESPACE="${PF_NAMESPACE}"
      SERVING_POD_SELECTOR="app=${aim_name}"
      info "deploy.sh (raw AIM) model detected: ${aim_name} → ${TARGET_URL}"
      if ! curl -sf -m 5 "${TARGET_URL}/v1/models" >/dev/null 2>&1; then
        warn "ClusterIP ${TARGET_URL} not reachable from here. If this host has"
        warn "no route to cluster IPs, re-run with: --port-forward ${aim_name}"
      fi
      return
    fi
    warn "Found deployment '${aim_name}' but could not resolve its Service ClusterIP; skipping raw-track auto-detect."
  fi

  # 2. Operator (start.sh) track: a Ready InferenceService predictor (ClusterIP).
  local k8s_name
  k8s_name=$(kubectl get inferenceservice -n "${PF_NAMESPACE}" -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' \
    2>/dev/null | head -n1 || true)

  if [ -n "${k8s_name}" ]; then
    local svc_ip
    svc_ip=$(kubectl get svc "${k8s_name}-predictor" -n "${PF_NAMESPACE}" \
      -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -z "${svc_ip}" ]; then
      err "Found K8s model '${k8s_name}' but could not resolve its predictor ClusterIP."
    fi
    TARGET_URL="http://${svc_ip}"
    SERVING_NAMESPACE="${PF_NAMESPACE}"
    SERVING_POD_SELECTOR="serving.kserve.io/inferenceservice=${k8s_name}"
    info "Operator predictor detected: ${k8s_name} → ${TARGET_URL}"
  else
    TARGET_URL="http://localhost:8000"
    info "No K8s serving endpoint found, falling back to Docker endpoint: ${TARGET_URL}"
  fi
}

detect_model_id() {
  if [ -n "${MODEL_ID}" ]; then
    info "Using provided MODEL_ID: ${MODEL_ID}"
    return
  fi

  info "Fetching model ID from ${TARGET_URL}/v1/models ..."
  MODEL_ID=$(curl -sf "${TARGET_URL}/v1/models" \
    | jq -r '.data[0].id' 2>/dev/null || true)

  if [ -z "${MODEL_ID}" ] || [ "${MODEL_ID}" = "null" ]; then
    warn "Could not fetch model ID from endpoint. Set --model-id manually."
    MODEL_ID="unknown"
  fi
  info "Model ID: ${MODEL_ID}"
}

# -----------------------------------------------------------------------------
# Performance sweep
# -----------------------------------------------------------------------------
run_perf_sweep() {
  sep
  info "Starting Performance Benchmark Sweep"
  sep

  declare -A useCases
  useCases["Generation"]="1024/8192"
  useCases["Translation"]="1024/1024"
  useCases["Summarization"]="8192/1024"

  local concurrencies=(1 2 4 8 16 32)
  local sweep_dir="${OUTPUT_DIR}/benchmarks/sweep"
  mkdir -p "${sweep_dir}"

  # ------ Benchmark runner ---------------------------------------------------
  run_single() {
    local name="$1" isl="$2" osl="$3" concurrency="$4"

    local report_dir="/workspace/reports/sweep/${name}/CON${concurrency}"
    local host_report_dir="${sweep_dir}/${name}/CON${concurrency}"
    mkdir -p "${host_report_dir}"

    local temp_config
    temp_config=$(mktemp "${WORKDIR}/scripts/temp_config_XXXXXX.yaml")
    # Safety net if docker run aborts under set -e: remove the temp config AND
    # still run the global cleanup (port-forward / pod-log capture).
    # shellcheck disable=SC2064
    trap "rm -f '${temp_config}'; cleanup" EXIT

    local num_requests=$(( concurrency < 10 ? 30 : concurrency * 3 ))

    # Vary input length 80-100% of the target (InferenceMAX-style). The
    # "random" datagen builds prompts directly from random token IDs, which
    # reliably reaches high token targets (e.g. ISL=8192) that the "synthetic"
    # text converger cannot hit with efficient tokenizers like gpt-oss.
    local isl_min=$(( isl * 80 / 100 ))
    local isl_mean=$(( (isl_min + isl) / 2 ))
    local isl_std=$(( (isl - isl_min) / 4 ))
    (( isl_std < 1 )) && isl_std=1

    cat <<EOF > "${temp_config}"
server:
  type: "vllm"
  base_url: "${TARGET_URL}"
  model_name: "${MODEL_ID}"
  ignore_eos: true

api:
  type: "completion"
  streaming: true

tokenizer:
  pretrained_model_name_or_path: "${TOKENIZER}"

data:
  type: "random"
  input_distribution:
    min: ${isl_min}
    max: ${isl}
    mean: ${isl_mean}
    std_dev: ${isl_std}
    total_count: ${num_requests}
  output_distribution:
    min: ${osl}
    max: ${osl}
    mean: ${osl}
    std_dev: 0
    total_count: ${num_requests}

load:
  type: "concurrent"
  num_workers: 4
  stages:
    - num_requests: ${num_requests}
      concurrency_level: ${concurrency}

storage:
  local_storage:
    path: "${report_dir}"
EOF

    # Pass HF_TOKEN so the container can fetch gated/private tokenizers
    # (e.g. openai/gpt-oss-120b). Harmless when unset or for public tokenizers.
    docker run --rm --net=host \
      -e "HF_TOKEN=${HF_TOKEN:-}" \
      -e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}" \
      -v "${temp_config}:/workspace/config.yml" \
      -v "${sweep_dir}:/workspace/reports/sweep" \
      quay.io/inference-perf/inference-perf \
      python inference_perf/main.py --config_file config.yml

    rm -f "${temp_config}"
    # Restore the global cleanup hook (do not leave EXIT unhandled).
    trap cleanup EXIT
  }

  run_use_case() {
    local name="$1" isl="$2" osl="$3"
    log "=== Use Case: ${name}  ISL=${isl}  OSL=${osl} ==="
    for c in "${concurrencies[@]}"; do
      log "  → Concurrency ${c}"
      run_single "${name}" "${isl}" "${osl}" "${c}"
    done
  }

  # Warmup — triggers aiter JIT HIP kernel compilation before timed runs
  log "=== Warmup pass (ISL=200, OSL=32) ==="
  run_single "Warmup" 200 32 1

  # Benchmark each use case
  for name in "${!useCases[@]}"; do
    IFS='/' read -r isl osl <<< "${useCases[$name]}"
    run_use_case "${name}" "${isl}" "${osl}"
  done

  sep
  info "Performance sweep complete. Results in: ${sweep_dir}"
  sep

  # ------ Consolidate metrics with Python ------------------------------------
  info "Parsing metrics and writing sweep_results.json ..."

  python3 - <<PYEOF
import os, json

use_cases = ["Generation", "Translation", "Summarization"]
concurrencies = [1, 2, 4, 8, 16, 32]
sweep_dir = "${sweep_dir}"

empty_use_cases = []   # produced zero usable stages
missing_stages  = []   # individual stages with no metrics

for use_case in use_cases:
    base_dir = os.path.join(sweep_dir, use_case)
    sweep_data = []
    present = 0

    print(f"\n{'='*60}")
    print(f"  {use_case}")
    print(f"{'='*60}")
    print(f"  {'Concurrency':<12} | {'TPS':<22} | {'Avg TTFT (s)':<12}")
    print(f"  {'-'*50}")

    for con in concurrencies:
        report_path = os.path.join(base_dir, f"CON{con}", "summary_lifecycle_metrics.json")
        tps = ttft = None
        ok_count = 0
        if os.path.exists(report_path):
            try:
                with open(report_path) as f:
                    m = json.load(f)
                # Metrics are nested under "successes"; TTFT lives under
                # successes.latency.time_to_first_token (populated when the
                # benchmark runs with streaming enabled).
                s = m.get("successes", {}) or {}
                ok_count = s.get("count", 0) or 0
                tps  = s.get("throughput", {}).get("total_tokens_per_sec", 0.0)
                lat  = s.get("latency", {}) or {}
                ttft_obj = lat.get("time_to_first_token") or {}
                ttft = ttft_obj.get("mean") if isinstance(ttft_obj, dict) else None
                if ttft is None:
                    ttft = lat.get("request_latency", {}).get("mean")
            except (ValueError, OSError):
                tps = ttft = None
                ok_count = 0

        # A stage is usable only if it had successful requests and throughput.
        if ok_count > 0 and tps is not None and tps > 0:
            present += 1
            ttft_str = f"{ttft:.3f}" if ttft is not None else "n/a"
            print(f"  {con:<12} | {tps:<22.2f} | {ttft_str:<12}")
            sweep_data.append({"concurrency": con, "throughput": tps, "ttft": ttft})
        else:
            missing_stages.append(f"{use_case}/CON{con}")
            print(f"  {con:<12} | {'N/A (no data)':<22} | {'N/A':<12}")

    if present == 0:
        empty_use_cases.append(use_case)
        print(f"\n  WARNING: {use_case} produced no usable results across all "
              f"concurrency levels.")

    out = os.path.join(base_dir, "sweep_results.json")
    os.makedirs(base_dir, exist_ok=True)
    with open(out, "w") as f:
        json.dump(sweep_data, f, indent=2)
    print(f"\n  Saved: {out}")

status = {
    "empty_use_cases": empty_use_cases,
    "missing_stages": missing_stages,
    "ok": len(empty_use_cases) == 0,
}
with open(os.path.join(sweep_dir, "sweep_status.json"), "w") as f:
    json.dump(status, f, indent=2)
PYEOF

  PERF_STATUS_FILE="${sweep_dir}/sweep_status.json"
}

# -----------------------------------------------------------------------------
# Accuracy evaluation
# -----------------------------------------------------------------------------
# Surface the real server-side failure behind an accuracy HTTP 500. Scans the
# streamed pod log for the known fatal signatures and prints a focused excerpt,
# then points at the full capture for deeper inspection.
dump_server_error() {
  local server_log="$1" acc_dir="$2"
  sep
  warn "Accuracy eval reported request error(s) (e.g. HTTP 500). Server-side diagnostics:"

  # If the live stream captured nothing, grab a recent tail directly as a fallback.
  if [ ! -s "${server_log}" ] && command -v kubectl >/dev/null 2>&1 && [ -n "${SERVING_POD_SELECTOR}" ]; then
    info "Streamed log was empty; fetching a recent tail directly from the pod(s) ..."
    kubectl logs --tail=400 --prefix -l "${SERVING_POD_SELECTOR}" \
      -n "${SERVING_NAMESPACE}" > "${server_log}" 2>&1 || true
  fi

  if [ ! -s "${server_log}" ]; then
    warn "No server pod logs could be captured. Re-run with --port-forward <svc> or"
    warn "ensure kubectl can reach the serving namespace, then inspect the pod manually."
    sep
    return 0
  fi

  local sig_file="${acc_dir}/server_error.signature.log"
  # Known fatal signatures: NaN/Inf logprobs that fail JSON serialization, plus
  # generic tracebacks / 500s logged by vLLM / uvicorn.
  grep -nEi 'not JSON compliant|Out of range float|\bnan\b|\binf\b|Traceback|Exception|Internal Server Error|ValueError|AssertionError' \
    "${server_log}" 2>/dev/null | tail -n 80 > "${sig_file}" || true

  if [ -s "${sig_file}" ]; then
    warn "Matched server-side error signatures (full capture: ${server_log}):"
    sed 's/^/    /' "${sig_file}"
    if grep -qiE 'not JSON compliant|Out of range float' "${sig_file}"; then
      sep
      warn "ROOT CAUSE CONFIRMED: the server produced non-finite (NaN/Inf) logprobs"
      warn "that cannot be JSON-serialized — this is what triggers the HTTP 500s."
    fi
  else
    warn "No known error signature matched. Inspect the full capture: ${server_log}"
  fi
  sep
}

run_accuracy_eval() {
  sep
  info "Starting Accuracy Evaluation (MMLU + GSM8K)"
  sep

  local acc_dir="${OUTPUT_DIR}/accuracy"
  mkdir -p "${acc_dir}"

  # Verify lm_eval and its API dependencies are installed
  if ! python3 -c "import lm_eval; import tenacity" &>/dev/null; then
    warn "lm_eval or API dependencies not found. Installing lm_eval[vllm,api] ..."
    pip install --quiet "lm_eval[vllm,api]"
  fi

  # MMLU uses the GENERATIVE flan variant (generate_until + answer extraction)
  # rather than the default loglikelihood scoring. The loglikelihood path returns
  # token logprobs, and gpt-oss-120b (mxfp4) occasionally emits a NaN logprob that
  # vLLM's /v1/completions cannot JSON-serialize → HTTP 500. Generation-only tasks
  # never request logprobs, so they sidestep that failure entirely.
  log "Running lm_eval — tasks: gsm8k, mmlu_flan_n_shot_generative — fewshot: 5"
  log "Model     : ${MODEL_ID}"
  log "TP size   : ${TENSOR_PARALLEL}"
  log "Max len   : ${MAX_MODEL_LEN}"

  # Capture the server's own logs for the duration of the eval so that if a
  # request 500s we keep the real traceback (it otherwise rotates out of the
  # pod log before it can be inspected).
  local server_log="${acc_dir}/server.pod.log"
  start_pod_log_capture "${server_log}"

  set +e
  python3 -m lm_eval \
    --model local-completions \
    --model_args "model=${MODEL_ID},base_url=${TARGET_URL}/v1/completions,num_concurrent=16,tokenized_requests=False,tokenizer=${MODEL_ID}" \
    --tasks gsm8k,mmlu_flan_n_shot_generative \
    --num_fewshot 5 \
    --batch_size 1 \
    --gen_kwargs max_gen_toks=2048 \
    --output_path "${acc_dir}/"
  local lm_rc=$?
  set -e

  stop_pod_log_capture

  if [ "${lm_rc}" -ne 0 ]; then
    ACC_OK=0
    warn "lm_eval exited with status ${lm_rc}."
    dump_server_error "${server_log}" "${acc_dir}"
  else
    info "lm_eval completed cleanly. Server log capture: ${server_log}"
  fi

  sep
  info "Accuracy evaluation complete. Results in: ${acc_dir}"
  sep

  # ------ Parse and summarise ------------------------------------------------
  info "Parsing accuracy results ..."

  python3 - <<PYEOF
import json, glob, os

result_files = sorted(glob.glob("${acc_dir}/**/*.json", recursive=True))
if not result_files:
    print("No result files found in ${acc_dir}")
    exit(0)

with open(result_files[-1]) as f:
    data = json.load(f)

results = data.get("results", {})

# Pick the best available score from a result entry, tolerating both the
# generative MMLU metric (exact_match with strict/flexible filters) and the
# older loglikelihood metric (acc).
def pick_score(entry):
    for m in ("exact_match,strict-match", "exact_match,flexible-extract",
              "acc,none", "exact_match,none"):
        if entry.get(m) is not None:
            return entry[m]
    return None

# Prefer the generative MMLU group aggregate; fall back to averaging subjects.
mmlu_avg = pick_score(results.get("mmlu_flan_n_shot_generative", {}))
if mmlu_avg is None:
    subj = [pick_score(v) for k, v in results.items()
            if k.startswith("mmlu_flan_n_shot_generative_")]
    subj = [s for s in subj if s is not None]
    mmlu_avg = sum(subj) / len(subj) if subj else None
# Last-resort fallback for older loglikelihood-style result files.
if mmlu_avg is None:
    legacy = [v["acc,none"] for k, v in results.items()
              if k.startswith("mmlu_") and "acc,none" in v]
    if legacy:
        mmlu_avg = sum(legacy) / len(legacy)
    else:
        mmlu_avg = results.get("mmlu", {}).get("acc,none")

gsm = results.get("gsm8k", {})
strict  = gsm.get("exact_match,strict-match")
flexible = gsm.get("exact_match,flexible-extract")

print("\n" + "="*50)
print("  Accuracy Summary")
print("="*50)
if mmlu_avg is not None:
    print(f"  MMLU 5-shot (generative) : {mmlu_avg:.4f}")
if strict is not None:
    print(f"  GSM8K strict-match       : {strict:.4f}")
if flexible is not None:
    print(f"  GSM8K flexible-extract   : {flexible:.4f}")
print("="*50 + "\n")

# Write summary JSON
summary = {
    "model": "${MODEL_ID}",
    "mmlu_5shot": mmlu_avg,
    "gsm8k_strict_match": strict,
    "gsm8k_flexible_extract": flexible,
}
out = "${acc_dir}/accuracy_summary.json"
with open(out, "w") as f:
    json.dump(summary, f, indent=2)
print(f"  Summary saved: {out}")
PYEOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Set up output dir and tee FIRST so the entire run (including the header) is captured
mkdir -p "${OUTPUT_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1
ln -sf "$(basename "${LOG_FILE}")" "${LOG_LATEST}"

sep
log "AMD Enterprise AI Benchmarking"
log "Mode       : ${MODE}"
log "Output dir : ${OUTPUT_DIR}"
log "Log file   : ${LOG_FILE}"
sep

if [ -n "${PORT_FORWARD}" ]; then
  start_port_forward
fi

detect_endpoint
detect_model_id

# Default the synthetic-data tokenizer to the served model so prompt token
# counts match reality. Falling back to gpt2 (model_max_length=1024) silently
# breaks long-context use cases like Summarization (ISL=8192).
if [ -z "${TOKENIZER}" ]; then
  if [ -n "${MODEL_ID}" ] && [ "${MODEL_ID}" != "unknown" ]; then
    TOKENIZER="${MODEL_ID}"
  else
    TOKENIZER="gpt2"
    warn "Model ID unknown; falling back to gpt2 tokenizer. Long-context"
    warn "use cases (ISL > 1024) will fail. Pass --tokenizer or --model-id."
  fi
fi
info "Tokenizer  : ${TOKENIZER}"

PERF_STATUS_FILE=""
ACC_OK=1

if [[ "${MODE}" == "perf" || "${MODE}" == "all" ]]; then
  run_perf_sweep
fi

if [[ "${MODE}" == "accuracy" || "${MODE}" == "all" ]]; then
  run_accuracy_eval
fi

sep

# Evaluate perf sweep outcome (if it ran) before declaring success.
PERF_OK=1
if [ -n "${PERF_STATUS_FILE}" ] && [ -f "${PERF_STATUS_FILE}" ]; then
  EMPTY_CASES=$(jq -r '.empty_use_cases | join(", ")' "${PERF_STATUS_FILE}" 2>/dev/null || true)
  MISSING_COUNT=$(jq -r '.missing_stages | length' "${PERF_STATUS_FILE}" 2>/dev/null || echo 0)
  if [ -n "${EMPTY_CASES}" ]; then
    PERF_OK=0
    warn "Performance sweep had use cases with NO usable data: ${EMPTY_CASES}"
    warn "Common cause: tokenizer cannot generate the requested input length."
    warn "Verify --tokenizer matches the served model (current: ${TOKENIZER})."
  elif [ "${MISSING_COUNT}" != "0" ]; then
    warn "Performance sweep completed with ${MISSING_COUNT} stage(s) missing data."
  fi
fi

if [ "${ACC_OK}" -ne 1 ]; then
  log "Done with FAILURES — accuracy eval hit server-side request errors (see diagnostics above)."
elif [ "${PERF_OK}" -eq 1 ]; then
  log "Done. All requested benchmarks completed successfully."
else
  log "Done with WARNINGS — some benchmark stages produced no data (see above)."
fi
log "Results : ${OUTPUT_DIR}/"
log "Log     : ${LOG_FILE}"
log "Latest  : ${LOG_LATEST}"
sep

# Non-zero exit so CI/automation notices: 4 = accuracy request errors,
# 3 = a perf use case produced no data.
[ "${ACC_OK}" -eq 1 ]  || exit 4
[ "${PERF_OK}" -eq 1 ] || exit 3
