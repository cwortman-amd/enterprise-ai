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
#   --model-id MODEL           Override model ID (skips curl auto-detect)
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
MODEL_ID="${MODEL_ID:-}"
TENSOR_PARALLEL=8
MAX_MODEL_LEN=16384
OUTPUT_DIR="results"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    --model-id)        MODEL_ID="$2";        shift 2 ;;
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

# Ensure OUTPUT_DIR is an absolute path
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="${WORKDIR}/${OUTPUT_DIR}"
fi

# Datetime stamp shared by the log file and any per-run outputs
DT="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${OUTPUT_DIR}/benchmark.${DT}.log"
LOG_LATEST="${OUTPUT_DIR}/benchmark.latest.log"

# -----------------------------------------------------------------------------
# Endpoint auto-detection
# -----------------------------------------------------------------------------
detect_endpoint() {
  if [ -n "${TARGET_URL}" ]; then
    info "Using provided TARGET_URL: ${TARGET_URL}"
    return
  fi

  info "Auto-detecting serving endpoint..."

  local k8s_name
  k8s_name=$(kubectl get inferenceservice -n default -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' \
    2>/dev/null | head -n1 || true)

  if [ -n "${k8s_name}" ]; then
    local svc_ip
    svc_ip=$(kubectl get svc "${k8s_name}-predictor" -n default \
      -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -z "${svc_ip}" ]; then
      err "Found K8s model '${k8s_name}' but could not resolve its predictor ClusterIP."
    fi
    TARGET_URL="http://${svc_ip}"
    info "K8s predictor detected: ${k8s_name} → ${TARGET_URL}"
  else
    TARGET_URL="http://localhost:8000"
    info "No K8s service found, falling back to Docker endpoint: ${TARGET_URL}"
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
    # shellcheck disable=SC2064
    trap "rm -f '${temp_config}'" EXIT

    local num_requests=$(( concurrency < 10 ? 30 : concurrency * 3 ))

    cat <<EOF > "${temp_config}"
server:
  type: "vllm"
  base_url: "${TARGET_URL}"
  model_name: "${MODEL_ID}"

tokenizer:
  pretrained_model_name_or_path: "gpt2"

data:
  type: "synthetic"
  input_distribution:
    type: "fixed"
    mean: ${isl}
    min: ${isl}
    max: ${isl}
  output_distribution:
    type: "fixed"
    mean: ${osl}
    min: ${osl}
    max: ${osl}

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

    docker run --rm --net=host \
      -v "${temp_config}:/workspace/config.yml" \
      -v "${sweep_dir}:/workspace/reports/sweep" \
      quay.io/inference-perf/inference-perf \
      python inference_perf/main.py --config_file config.yml

    rm -f "${temp_config}"
    trap - EXIT
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
import os, json, glob

use_cases = ["Generation", "Translation", "Summarization"]
concurrencies = [1, 2, 4, 8, 16, 32]
sweep_dir = "${sweep_dir}"

for use_case in use_cases:
    base_dir = os.path.join(sweep_dir, use_case)
    sweep_data = []

    print(f"\n{'='*60}")
    print(f"  {use_case}")
    print(f"{'='*60}")
    print(f"  {'Concurrency':<12} | {'TPS':<22} | {'Avg TTFT (s)':<12}")
    print(f"  {'-'*50}")

    for con in concurrencies:
        report_path = os.path.join(base_dir, f"CON{con}", "summary_lifecycle_metrics.json")
        if os.path.exists(report_path):
            with open(report_path) as f:
                m = json.load(f)
            tps  = m.get("throughput", {}).get("total_tokens_per_sec", 0.0)
            ttft = m.get("request_latency", {}).get("mean", 0.0)
            print(f"  {con:<12} | {tps:<22.2f} | {ttft:<12.3f}")
            sweep_data.append({"concurrency": con, "throughput": tps, "ttft": ttft})
        else:
            print(f"  {con:<12} | {'N/A':<22} | {'N/A':<12}")

    out = os.path.join(base_dir, "sweep_results.json")
    os.makedirs(base_dir, exist_ok=True)
    with open(out, "w") as f:
        json.dump(sweep_data, f, indent=2)
    print(f"\n  Saved: {out}")
PYEOF
}

# -----------------------------------------------------------------------------
# Accuracy evaluation
# -----------------------------------------------------------------------------
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

  log "Running lm_eval — tasks: gsm8k, mmlu — fewshot: 5"
  log "Model     : ${MODEL_ID}"
  log "TP size   : ${TENSOR_PARALLEL}"
  log "Max len   : ${MAX_MODEL_LEN}"

  python3 -m lm_eval \
    --model local-completions \
    --model_args "model=${MODEL_ID},base_url=${TARGET_URL}/v1/completions,num_concurrent=16,tokenized_requests=False,tokenizer=${MODEL_ID}" \
    --tasks gsm8k,mmlu \
    --num_fewshot 5 \
    --batch_size 1 \
    --gen_kwargs max_gen_toks=2048 \
    --output_path "${acc_dir}/"

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

mmlu_scores = [v["acc,none"] for k, v in results.items() if k.startswith("mmlu_")]
if mmlu_scores:
    mmlu_avg = sum(mmlu_scores) / len(mmlu_scores)
else:
    mmlu_avg = results.get("mmlu", {}).get("acc,none")

gsm = results.get("gsm8k", {})
strict  = gsm.get("exact_match,strict-match")
flexible = gsm.get("exact_match,flexible-extract")

print("\n" + "="*50)
print("  Accuracy Summary")
print("="*50)
if mmlu_avg is not None:
    print(f"  MMLU 5-shot accuracy     : {mmlu_avg:.4f}")
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

detect_endpoint
detect_model_id

if [[ "${MODE}" == "perf" || "${MODE}" == "all" ]]; then
  run_perf_sweep
fi

if [[ "${MODE}" == "accuracy" || "${MODE}" == "all" ]]; then
  run_accuracy_eval
fi

sep
log "Done. All requested benchmarks completed successfully."
log "Results : ${OUTPUT_DIR}/"
log "Log     : ${LOG_FILE}"
log "Latest  : ${LOG_LATEST}"
sep
