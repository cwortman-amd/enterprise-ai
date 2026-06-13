# BNY–AMD MI355X POC Quickstart Guide

AMD Enterprise AI Reference Stack | June 2026

This guide provides step-by-step instructions for executing the BNY POC Test Plan using the AMD Enterprise AI stack. Each section maps directly to the POC workload categories.

> [!IMPORTANT]
> **MI355X Note:** Normal POC runs should use `scripts/start.sh`. It applies this repository's custom MI355X `AIMClusterServiceTemplate` resources before creating `AIMService` objects. If you write manual AIMService manifests without those custom templates, include `allowUnoptimized: true` or the service can remain stuck in **Pending** indefinitely (`GPU not in cluster` condition).

---

## Quick Reference

| Item | Value |
| :--- | :--- |
| AMD Resource Manager | `https://airmui.<ip>.nip.io` |
| AMD AI Workbench | `https://aiwbui.<ip>.nip.io` |
| Default Login | `devuser@<ip>.nip.io` / `password` |
| ROCm Version | 7.0.2 (required) |
| AIM Catalog Version | 0.11.0 |
| Model launcher | `scripts/start.sh` |

### Expected Durations

| Activity | Typical Duration | Notes |
| :--- | :--- | :--- |
| Environment validation commands | 1-3 minutes | `kubectl` checks should return quickly once the cluster is healthy |
| `scripts/start.sh` with a warm cache | 5-20 minutes | Includes stopping any previous model, freeing GPUs, starting the predictor, and readiness checks |
| First download/cache for Llama 3.3 70B or GPT-OSS 120B | 15-45+ minutes | Requires `HF_TOKEN` or `HUGGING_FACE_HUB_TOKEN` in the environment or `scripts/.env` |
| First download/cache for Mixtral 8x22B | 30-60+ minutes | Larger cache and 8-GPU serving footprint; network and storage speed dominate |
| Switching from a smaller model to Mixtral | 10-30 minutes after cache is warm | Existing GPU-serving pods must terminate before Mixtral can schedule all 8 GPUs |
| Predictor pod `Running` but not `Ready` | 5-20 minutes | Normal while model weights load and vLLM/KServe readiness probes wait for port `8000` |
| Endpoint smoke test | Seconds after readiness | `start.sh` checks `/v1/models` and `/v1/completions` before printing `TARGET_URL` |
| Full performance sweep | 30-180+ minutes | Depends on selected model, OSL, concurrency range, and request count |

---

## 1. Environment Validation

Before running any benchmarks, validate the cluster is healthy.

```bash
# All nodes Ready?
kubectl get nodes -o wide

# MI355X GPUs visible to Kubernetes?
kubectl get nodes -o json \
  | jq -r '.items[] | "\(.metadata.name): \(.status.allocatable["amd.com/gpu"]) GPU(s)"'

# All platform pods running?
kubectl get pods -A | grep -Ev "Completed|Running"

# Check ingress routing is functional
kubectl get gateway -A && kubectl get httproute -A

# GPU detection from AIM Engine perspective
./scripts/debug.sh --gpu
```

Expected: 8 GPUs allocatable, all platform pods `Running`.

---

## 2. Memory-Intensive Model Benchmarking

### A. Deploy POC Benchmark Models

Use `start.sh` for normal POC runs. It validates Hugging Face access when a download is needed, reuses warm caches, stops any previously running model before switching, waits for readiness, and prints the active endpoint.

```bash
# Default: llama-3-3-70b
./scripts/start.sh

# Select another model
./scripts/start.sh --model mixtral-8x22b
./scripts/start.sh --model gpt-oss-120b
```

For gated Hugging Face models, place the token in `scripts/.env` or export it before running:

```env
HF_TOKEN=hf_...
```

The reference manifests below show what the service resources represent:

```yaml
---
# Model 1: Meta Llama 3.3 70B Instruct
apiVersion: aim.silogen.ai/v1alpha1
kind: AIMService
metadata:
  name: llama-3-3-70b
  namespace: default
  labels:
    poc.bny.com/workload: memory-benchmark
spec:
  cacheModel: true
  model:
    ref: llama-3-3-70b-model-v11
  resources:
    limits:
      amd.com/gpu: "1"
    requests:
      amd.com/gpu: "1"
---
# Model 2: Mistral Mixtral 8x22B (MoE, 141B total / 39B active)
apiVersion: aim.silogen.ai/v1alpha1
kind: AIMService
metadata:
  name: mixtral-8x22b
  namespace: default
  labels:
    poc.bny.com/workload: memory-benchmark
spec:
  cacheModel: true
  model:
    ref: mixtral-8x22b-model-v11
  resources:
    limits:
      amd.com/gpu: "8"
    requests:
      amd.com/gpu: "8"
---
# Model 3: OpenAI GPT-OSS 120B (MoE, 117B total / 5.1B active)
apiVersion: aim.silogen.ai/v1alpha1
kind: AIMService
metadata:
  name: gpt-oss-120b
  namespace: default
  labels:
    poc.bny.com/workload: memory-benchmark
spec:
  cacheModel: true
  model:
    ref: gpt-oss-120b-model
  resources:
    limits:
      amd.com/gpu: "1"
    requests:
      amd.com/gpu: "1"
```

```bash
kubectl apply -f scripts/bny-custom-templates.yaml
kubectl apply -f scripts/gpt-oss-model.yaml
kubectl apply -f scripts/bny-poc-models.yaml
```

> [!NOTE]
> Applying all model manifests directly can request more GPUs than the node has available. Prefer `start.sh` when benchmarking one model at a time.

> [!NOTE]
> The `AIMService` examples above rely on the model and template resources in `scripts/bny-custom-templates.yaml` and `scripts/gpt-oss-model.yaml`. If you instead create image-based AIMService manifests manually, add `allowUnoptimized: true` on MI355X unless you provide an equivalent MI355X template.

### B. Monitor Deployment Progress

```bash
# High-level status of all services
kubectl get aimservices -n default

# Detailed status / debug a specific service
./scripts/debug.sh llama-3-3-70b default
./scripts/debug.sh gpt-oss-120b default

# Watch pods come up (large model caches can take 15-60+ minutes on first pull)
watch -n 10 'kubectl get pods -n default'

# Tail container logs during startup
kubectl logs -l aim.eai.amd.com/service.name=llama-3-3-70b -n default -f --tail=50
```

### C. Verify Model is Ready

```bash
# Option 1: Standard completions (Recommended for immediate verification)
MODEL_NAME=$(kubectl get inferenceservice -n default -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' 2>/dev/null)
SERVICE_IP=$(kubectl get svc "${MODEL_NAME}-predictor" -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
SERVICE_URL="http://${SERVICE_IP}"
MODEL_ID=$(curl -s "${SERVICE_URL}/v1/models" | jq -r '.data[0].id')

curl -s "${SERVICE_URL}/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_ID}"'",
    "prompt": "What is 2+2?",
    "max_tokens": 50
  }' | jq .

# Option 2: Chat completions (For models supporting chat templates)
MODEL_NAME=$(kubectl get inferenceservice -n default -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' 2>/dev/null)
SERVICE_IP=$(kubectl get svc "${MODEL_NAME}-predictor" -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
SERVICE_URL="http://${SERVICE_IP}"
MODEL_ID=$(curl -s "${SERVICE_URL}/v1/models" | jq -r '.data[0].id')

curl -s "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_ID}"'",
    "messages": [{"role": "user", "content": "What is 2+2?"}],
    "max_tokens": 50
  }' | jq .
```

### D. Benchmarking Execution

The models expose an **OpenAI-compatible API** endpoint. Run benchmarks using standard tooling targeting that endpoint.

**Recommended test dimensions (per POC plan):**

| Test | Parameters |
| :--- | :--- |
| Baseline latency | Single query, input=1024 tokens, output=128 tokens |
| Throughput scaling | 1 → 4 → 8 concurrent requests |
| Context stress | Input=4096 → 8192 → 16384 tokens |
| Stability | 30-min sustained load at 50% capacity |

**Monitor GPU utilization during benchmarks:**

```bash
# On the host node
rocm-smi --showmemuse --showuse

# GPU memory per device
rocm-smi --showmeminfo vram
```

---

## 3. Distributed / Scale-Out Testing

### A. Verify Multi-GPU Allocation

Large models (70B+) automatically span multiple GPUs via Tensor Parallelism.

```bash
# Check how many GPUs are allocated to each service
kubectl describe pod -l aim.eai.amd.com/service.name=llama-3-3-70b -n default \
  | grep -A 5 "Limits:\|Requests:"

# Expected output includes:
#   amd.com/gpu: 2   (or 4, 8 depending on model size and TP config)
```

### B. Measure Scaling Efficiency (1 → 8 GPUs)

The AIM Engine selects the Tensor Parallelism degree based on the model profile. To test different GPU counts, you can create separate `AIMService` resources pointing to the same image but with different runtime configs (if supported by the profile).

```bash
# Monitor inter-GPU communication (xGMI / Infinity Fabric utilization)
rocm-smi --showtoponuma

# Watch memory fragmentation across all 8 GPUs
watch -n 2 'rocm-smi --showmeminfo vram | grep -E "GPU|Used|Total"'
```

---

## 4. Kubernetes Enterprise Deployment Validation

AMD Enterprise AI runs natively on Kubernetes. The model deployments above already validate the core K8s deployment model.

### Validate Enterprise Readiness

```bash
# 1. Verify the AIM Engine operator is running
kubectl get pods -A | grep -i aim

# 2. Check KServe is healthy
kubectl get pods -n kserve

# 3. Check Longhorn storage health
kubectl get pods -n longhorn-system | grep -v Running

# 4. Simulate autoscaling: edit minReplicas/maxReplicas on InferenceService
ISVC=$(kubectl get inferenceservice -n default -l aim.eai.amd.com/service.name=llama-3-3-70b \
  -o jsonpath='{.items[0].metadata.name}')
kubectl patch inferenceservice "$ISVC" -n default \
  --type=merge -p '{"spec":{"predictor":{"minReplicas":1,"maxReplicas":2}}}'

# 5. View resource consumption in AMD Resource Manager UI
# Navigate to: https://airmui.<ip>.nip.io → Clusters → Node GPU Metrics
```

### Key Metrics to Record

- Pod scheduling time after `kubectl apply`
- Time from `Pending` → `Starting` → `Ready`
- Resource utilization during sustained load (from `rocm-smi` and the ARMUI dashboards)

---

## 5. End-to-End Agentic Workflow

AMD Enterprise AI supports agentic workflows through **Solution Blueprints** in the AI Workbench.

### A. Deploy an Agentic Blueprint (UI)

1. Log into **AMD AI Workbench** (`https://aiwbui.<ip>.nip.io`)
2. Navigate to **Solution Blueprints**
3. Select an agentic or RAG blueprint (e.g., OpenWebUI + LangChain)
4. Configure the backend API to point to your running inference service
5. Deploy into your Workspace

### B. Validate the Workflow

**Architecture tested:**

```text
User Prompt → LLM (Llama/Mixtral inference) → Tool Call → Response Synthesis
```

```bash
# Monitor agentic workflow latency breakdown via logs (blocking/follow mode)
# Note: This command will return "No resources found" until the OpenWebUI blueprint is deployed in Section 5.A
kubectl logs -n default -l app=openwebui -f | grep -i "latency\|time\|tool"
```

```bash
# Measure LLM call latency specifically
# 1. Fetch active model name that is currently Ready and get its ClusterIP
MODEL_NAME=$(kubectl get inferenceservice -n default -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' 2>/dev/null)
SERVICE_IP=$(kubectl get svc "${MODEL_NAME}-predictor" -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
SERVICE_URL="http://${SERVICE_IP}"

# 2. Debug deployed services and model endpoints
kubectl get inferenceservice -n default
curl -s "${SERVICE_URL}/v1/models" | jq -r '.data[0].id'

# 3. Retrieve model ID from the serving container and run the latency check
MODEL=$(curl -s "${SERVICE_URL}/v1/models" | jq -r '.data[0].id')
echo ${MODEL}

curl -s "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL}"'",
    "messages": [{"role": "user", "content": "Summarize the key risks in high-frequency trading in 3 bullets."}],
    "max_tokens": 200
  }' | jq
```

**Validation points:**

- Multi-step reasoning completes without timeout
- Tool call responses are integrated correctly
- Stable under 5 concurrent agentic sessions

---

## 6. POC Success Criteria Checklist

| Category | Criterion | Status |
| :--- | :--- | :--- |
| Hardware | Token throughput competitive with B200 baseline | ☐ |
| Hardware | Single-query latency within SLA targets | ☐ |
| Software | ROCm stack deploys without major friction | ☐ |
| Software | Framework compatibility (vLLM, KServe) validated | ☐ |
| Enterprise | K8s deployment complexity acceptable | ☐ |
| Enterprise | Enterprise AI UI comparable to NVAIE experience | ☐ |
| System | Kubernetes scheduling stable under GPU load | ☐ |
| System | Agentic workflow runs end-to-end | ☐ |

---

## 7. POC Timeline

| Week | Focus | Key Tasks |
| :--- | :--- | :--- |
| **Week 1** | Environment setup & validation | Install, GPU check, cluster health |
| **Week 2** | Memory-intensive benchmarking | Deploy 3 models, run throughput/latency benchmarks |
| **Week 3** | Distributed + K8s + Agentic | Multi-GPU tests, autoscaling, Blueprint deployment |
| **Week 4** | Optimization + reporting | Tune, compare vs. B200 baseline, final report |

---

## 8. Troubleshooting Quick Reference

```bash
# A service is stuck in Pending (replace mixtral-8x22b and default with your service name and namespace)
./scripts/debug.sh mixtral-8x22b default

# List all services and their states
./scripts/debug.sh --list

# Check GPU availability
./scripts/debug.sh --gpu

# Check AIM Engine operator logs
kubectl logs -n aim-engine -l app.kubernetes.io/component=controller --tail=50

# Force-delete a failed service and redeploy (replace mixtral-8x22b and default with your service details)
kubectl delete aimservice mixtral-8x22b -n default
kubectl apply -f scripts/bny-poc-models.yaml
```

See [INSTALL.md](INSTALL.md) for the full troubleshooting table.
